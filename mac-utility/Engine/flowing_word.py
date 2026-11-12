"""Local PDF reconstruction into native Word paragraphs, lists and tables.

The lightweight reader handles single-column prose and short side-by-side labels
without inventing newspaper columns. Complex tables/illustrations use pdf2docx.
No document content or styles are copied from a reference Word file.
"""
from __future__ import annotations
import collections, copy, hashlib, io, itertools, math, re, statistics, tempfile, unicodedata, uuid, zipfile
from pathlib import Path
from urllib.parse import urlsplit
import pymupdf
from docx import Document
from docx.enum.section import WD_SECTION_START
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_TAB_ALIGNMENT
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.opc.constants import RELATIONSHIP_TYPE
from docx.shared import Pt, RGBColor
from docx.text.run import Run
from docx.text.paragraph import Paragraph
from lxml import etree
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._c_m_a_p import CmapSubtable

BULLETS='\u2022\uf0b7\u25cf\u25e6\u2023\u2219'
FONT_ALIASES={'LiberationSans':'Arial','LiberationSerif':'Times New Roman','LiberationMono':'Courier New',
              'Carlito':'Calibri','Caladea':'Cambria','ArialMT':'Arial','TimesNewRomanPSMT':'Times New Roman',
              'Helvetica':'Arial','Times-Roman':'Times New Roman','Courier':'Courier New'}


def font_family(name):
    name=re.sub(r'^[A-Z]{6}\+','',name)
    base=re.sub(r'[-, ](BoldItalic|BoldItali|BoldOblique|Bold|Italic|Oblique|Regular|Roman)$','',name)
    return FONT_ALIASES.get(base,FONT_ALIASES.get(name,base))


def add_link(paragraph,url,text):
    """Create schema-valid p/hyperlink/r/t nodes, preserving visible link text."""
    if urlsplit(url).scheme.lower() not in ('http','https','mailto','tel'):
        return paragraph.add_run(text)
    link=OxmlElement('w:hyperlink')
    link.set(qn('r:id'),paragraph.part.relate_to(url,RELATIONSHIP_TYPE.HYPERLINK,is_external=True))
    run=OxmlElement('w:r');node=OxmlElement('w:t');node.set(qn('xml:space'),'preserve');node.text=text
    run.append(node);link.append(run);paragraph._p.append(link)
    return Run(run,paragraph)


def text_of(row):return ''.join(s['text'] for line in row['lines'] for s in line['spans'])

def split_aligned_line(line):
    """Recover tab-aligned labels even when a PDF encodes the gap as spaces."""
    characters=[(i,c) for i,span in enumerate(line['spans']) for c in span['chars']]
    visible=[i for i,(_,c) in enumerate(characters) if not c['c'].isspace()]
    if not visible:return []
    chunks=[];start=visible[0]
    for a,b in zip(visible,visible[1:]):
        if characters[b][1]['origin'][0]-characters[a][1]['bbox'][2]>line['size']*3:
            chunks.append(characters[start:a+1]);start=b
    chunks.append(characters[start:visible[-1]+1])
    parts=[]
    for chunk in chunks:
        part=dict(line,spans=[])
        for index,chars in itertools.groupby(chunk,key=lambda item:item[0]):
            chars=[char for _,char in chars]
            span=dict(line['spans'][index],chars=chars,text=''.join(c['c'] for c in chars))
            span['bbox']=(chars[0]['origin'][0],span['bbox'][1],chars[-1]['bbox'][2],span['bbox'][3])
            part['spans'].append(span)
        x0=chunk[0][1]['origin'][0];x1=chunk[-1][1]['bbox'][2]
        part['bbox']=(x0,line['bbox'][1],x1,line['bbox'][3])
        parts.append(part)
    return parts

def rows_on_page(page):
    rows=[]
    for block in page.get_text('rawdict',flags=pymupdf.TEXT_PRESERVE_LIGATURES|pymupdf.TEXT_PRESERVE_WHITESPACE)['blocks']:
        for line in block.get('lines',[]):
            for span in line['spans']:
                span['text']=''.join(c['c'] for c in span['chars'])
            if abs(line.get('dir',(1,0))[1])>.05:raise ValueError('Rotated text requires Page layout (text boxes).')
            if not any(s['text'].strip() for s in line['spans']):continue
            line=copy.deepcopy(line);line['baseline']=statistics.median(s['origin'][1] for s in line['spans'])
            line['size']=max(s['size'] for s in line['spans'])
            parts=split_aligned_line(line)
            if not parts:continue
            line=dict(line,spans=parts[0]['spans'],bbox=(parts[0]['bbox'][0],line['bbox'][1],parts[-1]['bbox'][2],line['bbox'][3]))
            target=None
            for row in reversed(rows[-4:]):
                overlap=min(row['bbox'][3],line['bbox'][3])-max(row['bbox'][1],line['bbox'][1])
                minimum=min(row['bbox'][3]-row['bbox'][1],line['bbox'][3]-line['bbox'][1])
                if abs(row['baseline']-line['baseline'])<1 or overlap>minimum*.6:
                    target=row;break
            if target:
                target['lines'].extend(parts)
                target['bbox']=(min(target['bbox'][0],line['bbox'][0]),min(target['bbox'][1],line['bbox'][1]),
                                max(target['bbox'][2],line['bbox'][2]),max(target['bbox'][3],line['bbox'][3]))
                if line['size']>target['size']:target['baseline']=line['baseline'];target['size']=line['size']
            else:rows.append({'lines':parts,'bbox':line['bbox'],'baseline':line['baseline'],'size':line['size']})
    rows.sort(key=lambda r:(r['baseline'],r['bbox'][0]))
    for row in rows:
        row['lines'].sort(key=lambda l:l['bbox'][0])
        row['text']=text_of(row)
        row['bullet']=row['text'].lstrip()[:1] in BULLETS and bool(row['text'].strip())
        letters=[s for l in row['lines'] for s in l['spans'] if any(c.isalpha() for c in s['text'])]
        row['bold']=bool(letters) and all(s['flags']&16 for s in letters)
        row['italic']=bool(letters) and all(s['flags']&2 for s in letters)
        row['side_by_side']=len(row['lines'])>1 and any(b['bbox'][0]-a['bbox'][2]>row['size']*3 for a,b in zip(row['lines'],row['lines'][1:]))
    return rows


def simple_page(page,rows):
    if page.get_images():return False
    if page.find_tables().tables:return False
    links=[pymupdf.Rect(link['from']) for link in page.get_links() if link.get('uri')]
    for drawing in page.get_drawings():
        # Word exports underlined links as thin filled rectangles. These can
        # be reconstructed as underlined Word links in the native path.
        for item in drawing['items']:
            if item[0]=='l' and abs(item[1].y-item[2].y)<=.5:continue
            if item[0]=='re' and drawing['type']=='f':
                rect=item[1]
                if 0<rect.height<=1.5 and rect.width>3*rect.height and any(link.contains(rect) for link in links):continue
            return False
    pairs=[r for r in rows if r['side_by_side']]
    if len(pairs)>max(4,len(rows)*.25):return False
    return bool(rows)


def group_paragraphs(rows,right):
    paragraphs=[]
    for row in rows:
        previous=paragraphs[-1][-1] if paragraphs else None
        continuation=False
        if previous and not row['bullet'] and not row['bold'] and not row['side_by_side'] and not previous['side_by_side']:
            first=paragraphs[-1][0]
            body_x=next((s['bbox'][0] for l in first['lines'] for s in l['spans'] if s['text'].strip() and s['text'].strip()[:1] not in BULLETS),first['bbox'][0])
            aligned=abs(row['bbox'][0]-body_x)<2
            same_style=row['italic']==previous['italic'] and abs(row['size']-previous['size'])<.3
            close=0<row['baseline']-previous['baseline']<=previous['size']*1.6
            full=previous['bbox'][2]>right-max(35,(right-body_x)*.16)
            continuation=aligned and same_style and close and full
        if continuation:paragraphs[-1].append(row)
        else:paragraphs.append([row])
    return paragraphs


def bullet_numbering(doc,size,family='Arial',marker='•',rise=0):
    root=doc.part.numbering_part.element
    aid=max([int(x.get(qn('w:abstractNumId'))) for x in root.findall(qn('w:abstractNum'))]+[-1])+1
    nid=max([int(x.get(qn('w:numId'))) for x in root.findall(qn('w:num'))]+[0])+1
    abstract=OxmlElement('w:abstractNum');abstract.set(qn('w:abstractNumId'),str(aid))
    level=OxmlElement('w:lvl');level.set(qn('w:ilvl'),'0')
    for tag,val in [('start','1'),('numFmt','bullet'),('lvlText',marker),('lvlJc','left')]:
        item=OxmlElement('w:'+tag);item.set(qn('w:val'),val);level.append(item)
    rpr=OxmlElement('w:rPr');fonts=OxmlElement('w:rFonts')
    for attr in ('ascii','hAnsi'):fonts.set(qn('w:'+attr),family)
    rpr.append(fonts)
    for tag in ('sz','szCs'):
        e=OxmlElement('w:'+tag);e.set(qn('w:val'),str(round(size*2)));rpr.append(e)
    if rise:
        position=OxmlElement('w:position');position.set(qn('w:val'),str(rise));rpr.insert_element_before(position,'w:sz','w:szCs')
        # Writer otherwise applies automatic superscript sizing to list marks.
        alignment=OxmlElement('w:vertAlign');alignment.set(qn('w:val'),'baseline');rpr.append(alignment)
    level.append(rpr);abstract.append(level);root.append(abstract)
    number=OxmlElement('w:num');number.set(qn('w:numId'),str(nid));ref=OxmlElement('w:abstractNumId');ref.set(qn('w:val'),str(aid));number.append(ref);root.append(number)
    return nid


def style_run(run,span,rise=0,baseline=None,end_x=None):
    run.font.name=font_family(span['font']);run._element.get_or_add_rPr().rFonts.set(qn('w:eastAsia'),run.font.name)
    size=span['size']
    # MuPDF reports the geometric mean of the horizontal and vertical
    # scales. Recover the actual height for stretched PDF headings.
    ascender=span.get('ascender',0)
    height=(span['origin'][1]-span['bbox'][1])/ascender if ascender>.1 else size
    if not .5*size<=height<=2*size:height=size
    word_size=max(.5,round(height*2)/2)
    run.font.size=Pt(word_size)
    run.bold=bool(span['flags']&16);run.italic=bool(span['flags']&2)
    if baseline is not None:
        rise+=round((baseline-span['origin'][1])*2)
        chars=span['chars']
        width_scale=round(size**2/(height*word_size)*100)
        if 25<=width_scale<=200 and abs(size/height-1)>.02:
            width=OxmlElement('w:w');width.set(qn('w:val'),str(width_scale))
            run._element.rPr.insert_element_before(width,'w:sz','w:szCs')
        else:width_scale=100
        if len(chars)>1 and run.text==span['text']:
            nominal=sum(c['bbox'][2]-c['origin'][0] for c in chars)*word_size*height/size**2*width_scale/100
            end=chars[-1]['bbox'][2] if end_x is None else end_x
            tracking=round(20*(end-chars[0]['origin'][0]-nominal)/len(chars))
            if 0<abs(tracking)<=round(word_size*5):
                spacing=OxmlElement('w:spacing');spacing.set(qn('w:val'),str(tracking))
                run._element.rPr.insert_element_before(spacing,'w:w','w:sz','w:szCs')
    if rise:
        position=OxmlElement('w:position');position.set(qn('w:val'),str(rise));run._element.rPr.insert_element_before(position,'w:sz','w:szCs','w:highlight','w:u','w:vertAlign')
    color=span.get('color',0);run.font.color.rgb=RGBColor((color>>16)&255,(color>>8)&255,color&255)
    # Explicit local shaping retains normal editable Unicode ligatures.
    lig=OxmlElement('w14:ligatures');lig.set(qn('w14:val'),'standardContextual');run._element.rPr.append(lig)


def paragraph_geometry(groups):
    """Fit native line boxes to source paragraph boundaries, in Word twips.

    PDF glyph bounds are not line boxes. Using them as paragraph starts with
    an unconstrained line height accumulates leading after wrapped paragraphs.
    Reserve only the available height, then preserve each source baseline with
    normal half-point run positioning. Text still wraps freely within one p;
    there are no forced line breaks, frames, or separate per-line paragraphs.
    """
    heights=[]
    for group in groups:
        first=group[0]
        steps=[b['baseline']-a['baseline'] for a,b in zip(group,group[1:])]
        height=statistics.median(steps) if steps else first['size']*1.12
        heights.append(round(height*20)/20)
    def place(group,height):
        first=group[0]
        rise=round((first['bbox'][1]+height*.8-first['baseline'])*2)
        top=round((first['baseline']-height*.8+rise*.5)*20)/20
        rises=[rise+round((i*height-(row['baseline']-first['baseline']))*2) for i,row in enumerate(group)]
        return top,height,rises
    geometry=[place(group,height) for group,height in zip(groups,heights)]
    # Reduce in half-point steps so run positioning can retain the original
    # line pitch exactly, even when two list items have a tight boundary.
    for index in range(len(groups)-2,-1,-1):
        top,height,rises=geometry[index];next_top=geometry[index+1][0]
        while top+height*len(groups[index])>next_top+.025 and height>.5:
            height=max(.5,height-.5);top,height,rises=place(groups[index],height)
        geometry[index]=(top,height,rises)
    return geometry


def span_link(span,links):
    box=pymupdf.Rect(span['bbox'])
    for link in links:
        if not link.get('uri'):continue
        rect=pymupdf.Rect(link['from']);inter=box&rect
        if box.width>0 and inter.width/box.width>.7 and inter.height>0:return link['uri']
    return None


def embed_bullet_fonts(data,document,families):
    """Keep symbol bullets visible in Word without a system font dependency."""
    if not families:return data
    with zipfile.ZipFile(io.BytesIO(data)) as z:files={n:z.read(n) for n in z.namelist()}
    w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'
    r='http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    rel='http://schemas.openxmlformats.org/package/2006/relationships'
    table=etree.fromstring(files['word/fontTable.xml'])
    rel_path='word/_rels/fontTable.xml.rels'
    relationships=etree.fromstring(files[rel_path]) if rel_path in files else etree.Element('{'+rel+'}Relationships',nsmap={None:rel})
    embedded=set()
    numbering=etree.fromstring(files['word/numbering.xml'])
    for page in document:
        traces=page.get_texttrace()
        for record in page.get_fonts():
            family=font_family(record[3])
            if family not in families or family in embedded:continue
            _,extension,_,raw=document.extract_font(record[0])
            if extension not in ('ttf','otf') or not raw:continue
            font=TTFont(io.BytesIO(raw));rights=font['OS/2'].fsType if 'OS/2' in font else 0
            if rights & (2|0x100|0x200):continue
            # Office symbol PDFs commonly map the bullet to the private-use
            # F0B7 slot. Native Unicode numbering needs the same glyph at 2022.
            for cmap in font['cmap'].tables:
                if cmap.isUnicode() and 0xf0b7 in cmap.cmap and 0x2022 not in cmap.cmap:
                    cmap.cmap[0x2022]=cmap.cmap[0xf0b7]
            if 0x2022 not in (font.getBestCmap() or {}):
                glyphs={character[1] for trace in traces if font_family(trace['font'])==family
                        for character in trace['chars'] if character[0] in (0xf0b7,0x2022)}
                if len(glyphs)!=1:continue
                glyph=next(iter(glyphs));order=font.getGlyphOrder()
                if not 0<glyph<len(order):continue
                cmap=CmapSubtable.newSubtable(12)
                cmap.platformID=3;cmap.platEncID=10;cmap.language=0
                cmap.cmap=dict(font.getBestCmap() or {});cmap.cmap[0x2022]=order[glyph]
                font['cmap'].tables.append(cmap)
            alias='EC Bullet '+hashlib.sha256(raw).hexdigest()[:10]
            for name in font['name'].names:
                if name.nameID in (1,3,4,6,16):
                    value=alias.replace(' ','') if name.nameID==6 else alias
                    name.string=value.encode(name.getEncoding(),errors='replace')
            buffer=io.BytesIO();font.save(buffer);raw=bytearray(buffer.getvalue())
            guid=uuid.uuid4()
            # ECMA-376 obfuscates the first 32 bytes with the reversed GUID.
            key=guid.bytes[::-1]
            for i in range(32):raw[i]^=key[i%16]
            number=len(embedded)+1;rid=f'ecBulletFont{number}';filename=f'ec-bullet-{number}.odttf'
            files['word/fonts/'+filename]=bytes(raw)
            node=etree.SubElement(table,'{'+w+'}font',{'{'+w+'}name':alias})
            etree.SubElement(node,'{'+w+'}embedRegular',{'{'+r+'}id':rid,'{'+w+'}fontKey':'{'+str(guid).upper()+'}','{'+w+'}subsetted':'true'})
            etree.SubElement(relationships,'{'+rel+'}Relationship',Id=rid,Type=r+'/font',Target='fonts/'+filename)
            embedded.add(family)
            for fonts in numbering.iter('{'+w+'}rFonts'):
                for attribute,value in list(fonts.attrib.items()):
                    if value==family:fonts.set(attribute,alias)
    if not embedded:return data
    files['word/fontTable.xml']=etree.tostring(table,xml_declaration=True,encoding='UTF-8',standalone=True)
    files[rel_path]=etree.tostring(relationships,xml_declaration=True,encoding='UTF-8',standalone=True)
    files['word/numbering.xml']=etree.tostring(numbering,xml_declaration=True,encoding='UTF-8',standalone=True)
    types=etree.fromstring(files['[Content_Types].xml']);ct='http://schemas.openxmlformats.org/package/2006/content-types'
    if not any(n.get('Extension')=='odttf' for n in types):
        etree.SubElement(types,'{'+ct+'}Default',Extension='odttf',ContentType='application/vnd.openxmlformats-officedocument.obfuscatedFont')
    files['[Content_Types].xml']=etree.tostring(types,xml_declaration=True,encoding='UTF-8',standalone=True)
    result=io.BytesIO()
    with zipfile.ZipFile(result,'w',zipfile.ZIP_DEFLATED) as z:
        for name,content in files.items():z.writestr(name,content)
    return result.getvalue()


def write_native(document,pages):
    doc=Document();normal=doc.styles['Normal'];normal.font.name='Arial'
    normal.font.size=Pt(statistics.median(r['size'] for _,rows in pages for r in rows))
    normal.paragraph_format.space_after=Pt(0);normal.paragraph_format.widow_control=False
    numbers={};count=0;bullet_families=set()
    for pi,(page,rows) in enumerate(pages):
        section=doc.sections[0] if pi==0 else doc.add_section(WD_SECTION_START.NEW_PAGE)
        left=min(r['bbox'][0] for r in rows);right=max(r['bbox'][2] for r in rows)
        section.page_width=Pt(page.rect.width);section.page_height=Pt(page.rect.height)
        section.left_margin=Pt(left);section.right_margin=Pt(max(12,page.rect.width-right))
        groups=group_paragraphs(rows,right);geometry=paragraph_geometry(groups)
        section.top_margin=Pt(max(0,geometry[0][0]));section.bottom_margin=Pt(max(12,min(36,page.rect.height-rows[-1]['bbox'][3])))
        section.header_distance=Pt(0);section.footer_distance=Pt(0)
        links=page.get_links();previous_end=geometry[0][0]
        for group,(top,line_height,rises) in zip(groups,geometry):
            first,last=group[0],group[-1];p=doc.add_paragraph();pf=p.paragraph_format
            text_spans=[s for l in first['lines'] for s in l['spans'] if s['text'].strip() and s['text'].strip()[:1] not in BULLETS]
            text_x=text_spans[0]['bbox'][0] if text_spans else first['bbox'][0]
            pf.line_spacing=Pt(line_height);pf.space_before=Pt(round(max(0,top-previous_end)*20)/20);pf.space_after=Pt(0)
            pf.widow_control=False;pf.keep_with_next=False
            pf.left_indent=Pt(max(0,(text_x if first['bullet'] else first['bbox'][0])-left));pf.right_indent=Pt(0)
            if len(group)>1 and max(row['bbox'][2] for row in group)>right-1:
                # The furthest visible glyph is only a lower bound on the
                # original wrap width. Allow for Word's font/rounding variance.
                pf.right_indent=Pt(-2)
            if first['bullet']:
                size=round(first['size']*2)/2
                bullet_span=next(s for l in first['lines'] for s in l['spans'] if s['text'].lstrip()[:1] in BULLETS)
                family=font_family(bullet_span['font']);marker=bullet_span['text'].lstrip()[0]
                if marker=='\uf0b7':marker='•';bullet_families.add(family)
                key=(size,family,marker,rises[0])
                if key not in numbers:numbers[key]=bullet_numbering(doc,size,family,marker,rises[0])
                pf.first_line_indent=Pt(first['bbox'][0]-text_x)
                num=p._p.get_or_add_pPr().get_or_add_numPr()
                num.get_or_add_ilvl().val=0;num.get_or_add_numId().val=numbers[key]
                pf.tab_stops.add_tab_stop(Pt(text_x-left))
            centered=not first['bullet'] and not first['side_by_side'] and first['bbox'][2]-first['bbox'][0]<(right-left)*.8 and abs((first['bbox'][0]+first['bbox'][2])/2-page.rect.width/2)<4
            if centered:
                pf.alignment=WD_ALIGN_PARAGRAPH.CENTER;pf.left_indent=Pt(0)
                # Preserve the PDF's actual center, including slight offsets.
                shift=first['bbox'][0]+first['bbox'][2]-left-right
                pf.left_indent=Pt(max(0,shift))
                pf.right_indent=Pt(max(0,-shift))
            if first['bold'] and not first['bullet']:
                p.style='Heading 1' if first['size']>statistics.median(r['size'] for r in rows)*1.03 else 'Normal'
                pf.keep_with_next=True
            for gi,row in enumerate(group):
                if gi:
                    prior=group[gi-1]['text'].rstrip()
                    if not prior.endswith('-'):style_run(p.add_run(' '),row['lines'][0]['spans'][0],rises[gi])
                for li,line in enumerate(row['lines']):
                    if li:
                        gap=line['bbox'][0]-row['lines'][li-1]['bbox'][2]
                        if gap>row['size']*3:
                            pf.tab_stops.add_tab_stop(Pt(line['bbox'][2]-left),WD_TAB_ALIGNMENT.RIGHT);style_run(p.add_run('\t'),line['spans'][0],rises[gi])
                        elif gap>row['size']*.15:style_run(p.add_run(' '),line['spans'][0],rises[gi])
                    strip_bullet=gi==0 and li==0 and first['bullet']
                    for si,span in enumerate(line['spans']):
                        text=span['text']
                        if si==len(line['spans'])-1:text=text.rstrip()
                        if strip_bullet:
                            text=text.lstrip(BULLETS+' \t')
                            strip_bullet=not bool(text)
                        if not text:continue
                        uri=span_link(span,links)
                        run=add_link(p,uri,text) if uri else p.add_run(text)
                        end_x=line['spans'][si+1]['bbox'][0] if si+1<len(line['spans']) else None
                        style_run(run,span,rises[gi],row['baseline'],end_x)
                        if uri:run.underline=True
            previous_end=top+line_height*len(group)
            count+=1
    stream=io.BytesIO();doc.save(stream)
    return embed_bullet_fonts(stream.getvalue(),document,bullet_families),count


def normalize(s):
    return ''.join(c for c in unicodedata.normalize('NFKC',s) if not c.isspace() and c not in BULLETS+'\u00ad\u200b')


def repair_table_lists(data,pages):
    """Turn source bullet glyphs into numbering after table reconstruction."""
    hints=[r for _,rows in pages for r in rows if r['bullet']]
    if not hints:return data
    doc=Document(io.BytesIO(data));numbers={}
    for node in doc.element.body.iter(qn('w:p')):
        p=Paragraph(node,doc);text=''.join(t.text or '' for t in node.iter(qn('w:t')))
        if not text.strip() or text.lstrip()[:1] not in BULLETS:continue
        hint=next((r for r in hints if normalize(text).startswith(normalize(r['text']))),None)
        if not hint:continue
        size=round(hint['size']*2)/2
        if size not in numbers:numbers[size]=bullet_numbering(doc,size)
        text_x=next((s['bbox'][0] for l in hint['lines'] for s in l['spans'] if s['text'].strip() and s['text'].strip()[:1] not in BULLETS),hint['bbox'][0]+size)
        gap=max(size*.7,text_x-hint['bbox'][0])
        fmt=p.paragraph_format;left=(fmt.left_indent.pt if fmt.left_indent is not None else 0)+gap
        fmt.left_indent=Pt(left);fmt.first_line_indent=Pt(-gap);fmt.tab_stops.clear_all();fmt.tab_stops.add_tab_stop(Pt(left))
        num=node.get_or_add_pPr().get_or_add_numPr();num.get_or_add_ilvl().val=0;num.get_or_add_numId().val=numbers[size]
        found=False
        for run in p.runs:
            for item in list(run._r):
                if item.tag==qn('w:t') and not found:
                    item.text=(item.text or '').lstrip(BULLETS+' \t');found=bool(item.text)
                elif item.tag==qn('w:tab') and not found:run._r.remove(item)
    out=io.BytesIO();doc.save(out);return out.getvalue()


def validate(data,source_text):
    ns={'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        root=etree.fromstring(z.read('word/document.xml'))
        if root.xpath('//w:txbxContent|//w:framePr',namespaces=ns):raise ValueError('The paragraph converter returned text boxes. No Word file was saved.')
        text=''.join(root.xpath('//w:t/text()',namespaces=ns))
        if not text.strip():raise ValueError('No editable paragraphs were reconstructed.')
        missing=collections.Counter(normalize(source_text))-collections.Counter(normalize(text))
        if missing:raise ValueError('Some source text is missing from the reconstructed paragraphs. No Word file was saved.')
        if collections.Counter(normalize(text))-collections.Counter(normalize(source_text)):
            raise ValueError('Reconstruction added unexpected text. No Word file was saved.')
    return text


def convert(source,destination):
    document=pymupdf.open(source)
    if document.needs_pass:raise ValueError('Password-protected PDFs are not supported.')
    if not 0<len(document)<=100:raise ValueError('Use a PDF with 1–100 pages.')
    source_text='';pages=[];native=True
    for page in document:
        page.remove_rotation()
        if max(page.rect.width,page.rect.height)>1584:raise ValueError('This PDF page exceeds Word’s 22-inch page limit.')
        if not page.get_text().strip() and page.get_images():raise ValueError(f'Page {page.number+1} needs OCR. Image-only Word pages will not be saved.')
        if any(re.search(r'CMEX|CMSY|CMMI|Math',f[3],re.I) for f in page.get_fonts()):
            raise ValueError('Equations in this PDF need Page layout (text boxes). Editable paragraphs cannot preserve these mathematical layouts reliably.')
        source_text+=page.get_text()
        if '\ufffd' in source_text:raise ValueError('This PDF has missing character mappings. No incomplete Word file was saved.')
        rows=rows_on_page(page);pages.append((page,rows));native=native and simple_page(page,rows)
    if native:
        data,count=write_native(document,pages)
    else:
        # Repair the library's invalid nested hyperlink markup at its source.
        from pdf2docx import Converter
        from pdf2docx.common import docx as docx_helpers
        original=docx_helpers.add_hyperlink;docx_helpers.add_hyperlink=add_link
        try:
            with tempfile.TemporaryDirectory(prefix='ec-paragraphs-') as tmp:
                path=Path(tmp)/'paragraphs.docx';converter=Converter(source)
                try:converter.convert(str(path),multi_processing=False,ignore_page_error=False,min_section_height=100)
                finally:converter.close()
                data=repair_table_lists(path.read_bytes(),pages)
        finally:docx_helpers.add_hyperlink=original
        count=0
    text=validate(data,source_text);Path(destination).write_bytes(data)
    return {'mode':'flowing','pages':len(document),'editable_characters':len(text),'paragraphs':count,'text_boxes':0,'engine':'native-flow' if native else 'table-flow'}
