"""Offline PDF -> DOCX with editable, positioned text and separate artwork.

Text is never hidden behind a full-page screenshot. PDF text is removed from the
artwork layer before rasterizing diagrams. PDF fonts are embedded when their
embedding flags permit it. Larger edits do not reflow across positioned boxes.
"""
from __future__ import annotations
import argparse, functools, hashlib, io, json, math, re, sys, tempfile, uuid, zipfile
from pathlib import Path
from xml.sax.saxutils import escape
import pymupdf
from PIL import Image, ImageChops
from fontTools import agl, t1Lib
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.recordingPen import RecordingPen, DecomposingRecordingPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._c_m_a_p import CmapSubtable

W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
REL = 'http://schemas.openxmlformats.org/package/2006/relationships'
DECL = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
MATH_UNICODE={'summationdisplay':0x2211,'summationtext':0x2211,'productdisplay':0x220F,'producttext':0x220F,
    'integraldisplay':0x222B,'integraltext':0x222B,'bracketlefttp':0x23A1,'bracketleftex':0x23A2,
    'bracketleftbt':0x23A3,'bracketrighttp':0x23A4,'bracketrightex':0x23A5,'bracketrightbt':0x23A6}

def xml(s):
    return escape(''.join(c for c in str(s) if c in '\t\n\r' or ord(c) >= 32), {'"':'&quot;'})

def glyph_signatures(font):
    """Compare actual outlines and advances, independent of subset glyph names."""
    glyphs=font.getGlyphSet();result={}
    for index,name in enumerate(font.getGlyphOrder()):
        pen=DecomposingRecordingPen(glyphs);glyphs[name].draw(pen)
        signature=(font['head'].unitsPerEm,font['hmtx'][name][0],repr(pen.value))
        result[index]=hashlib.sha256(repr(signature).encode()).digest()
    return result

@functools.lru_cache(maxsize=8)
def bundled_complete_font(name):
    # These complete, redistributable faces already ship with the office engine.
    # Never select a merely similar face or download a replacement font.
    filenames={family+suffix:family+'-'+style+'.ttf'
        for family in ('Carlito','Caladea')
        for suffix,style in (('', 'Regular'),('-Bold','Bold'),('-Italic','Italic'),('-BoldItalic','BoldItalic'))}
    filename=filenames.get(name)
    if not filename:return None
    relative=Path('LibreOfficeDev.app/Contents/Resources/fonts/truetype')/filename
    roots=(Path(sys.executable).resolve().parent.parent/'OfficeEngine',
           Path(__file__).resolve().parent.parent/'build/office-engine')
    for root in roots:
        path=root/relative
        if not path.is_file():continue
        data=path.read_bytes();font=TTFont(io.BytesIO(data))
        if 'OS/2' in font and font['OS/2'].fsType & 2:return None
        signatures=glyph_signatures(font)
        return data,{signature:index for index,signature in signatures.items()}
    return None

def complete_subset_font(font, name):
    """Recover a complete face only when every original glyph matches exactly.

    Some office PDFs split one face into several cmap-less subsets. Their
    multi-character glyphs (ft, ti, ffi, etc.) need the complete font's Unicode
    and shaping tables to stay normal editable text in Word.
    """
    if font.getBestCmap():return None
    complete=bundled_complete_font(name)
    if not complete:return None
    data,signatures=complete;mapping={}
    for index,signature in glyph_signatures(font).items():
        if index==0:continue
        if signature not in signatures:return None
        mapping[index]=signatures[signature]
    return data,mapping

def type1_to_otf(data, family):
    with tempfile.TemporaryDirectory(prefix='ec-font-') as tmp:
        path=Path(tmp)/'source.pfa'
        if b'cleartomark' not in data[-800:]:data+=b'\n'+b'0'*512+b'\ncleartomark\n'
        path.write_bytes(data)
        source=t1Lib.T1Font(str(path));source.parse()
        if source.font.get('FontInfo',{}).get('FSType',0) & 2:
            return None
        glyphset=source.getGlyphSet();order=list(glyphset)
        bounds=source.font.get('FontBBox',(-200,-300,1200,1000))
        # TeX extension fonts intentionally put large glyphs several em below
        # the baseline. Word clips those in a normal text line. Normalize the
        # outlines into one em and compensate with the Word run's font size.
        factor=max(1,math.ceil((bounds[3]-bounds[1])/1000)) if bounds[3]-bounds[1]>1800 else 1
        baseline_shift=800-math.ceil(bounds[3]/factor) if factor>1 else 0
        if '.notdef' not in order:order.insert(0,'.notdef')
        if 'space' not in order:order.append('space')
        metrics={};charstrings={}
        for name in order:
            recording=RecordingPen()
            if name in glyphset:
                glyphset[name].draw(recording);width=getattr(glyphset[name],'width',500)
            else:width=250 if name=='space' else 500
            pen=T2CharStringPen(width/factor,None);recording.replay(TransformPen(pen,(1/factor,0,0,1/factor,0,baseline_shift)))
            charstrings[name]=pen.getCharString();metrics[name]=(round(width/factor),0)
        cmap={}
        for name in order:
            value=agl.toUnicode(name)
            if len(value)==1:cmap[ord(value)]=name
            if name in MATH_UNICODE:cmap[MATH_UNICODE[name]]=name
        # Some PDF math glyphs have no Unicode mapping. Give those original
        # outlines private-use codes instead of emitting replacement characters.
        for index,name in enumerate(order):cmap[0xE000+index]=name
        aliases={'mu':[0x3bc,0xb5],'Omega':[0x3a9,0x2126],'Delta':[0x394,0x2206]}
        for name, values in aliases.items():
            if name in order:
                for value in values:cmap[value]=name
        fb=FontBuilder(1000,isTTF=False)
        fb.setupGlyphOrder(order);fb.setupCharacterMap(cmap)
        fb.setupCFF(family.replace(' ',''),{'FullName':family,'FamilyName':family,'Weight':'Regular'},charstrings,{})
        fb.setupHorizontalMetrics(metrics)
        # PDF baselines are positioned explicitly. Keep conventional ascent and
        # descent so Word and LibreOffice agree on the textbox baseline.
        ascent=800;descent=-200
        fb.setupHorizontalHeader(ascent=ascent,descent=descent)
        fb.setupNameTable({'familyName':family,'styleName':'Regular','uniqueFontIdentifier':family,'fullName':family,'psName':family.replace(' ','')})
        fb.setupOS2(sTypoAscender=ascent,sTypoDescender=descent,
            usWinAscent=ascent if factor>1 else max(1000,math.ceil(bounds[3])),
            usWinDescent=-descent if factor>1 else max(300,math.ceil(-bounds[1])),fsType=0)
        fb.setupPost()
        output=io.BytesIO();fb.save(output);return output.getvalue(),order,factor,baseline_shift/1000

def make_font(document, record):
    name,ext,kind,data=document.extract_font(record[0])
    plain=re.sub(r'^[A-Z]{6}\+','',name)
    family='EC '+re.sub('[^A-Za-z0-9 -]','',plain)[:27]+' '+hashlib.sha256(data+b'Docenlume-font-v4').hexdigest()[:8]
    try:
        order=[];factor=1;baseline_shift=0;source_glyph_ids=None;extraction_names={record[3]}
        if ext in ('pfa','pfb'):
            result=type1_to_otf(data,family)
            if not result:return None
            data,order,factor,baseline_shift=result
        elif ext in ('ttf','otf'):
            font=TTFont(io.BytesIO(data))
            if 'OS/2' in font and font['OS/2'].fsType & 2:return None
            prefix=record[3][:-len(plain)] if plain else ''
            for name_id in (1,4,6):
                value=font['name'].getDebugName(name_id)
                if value:extraction_names.add(prefix+re.sub(r'^[A-Z]{6}\+','',value))
            complete=complete_subset_font(font,plain)
            if complete:
                data,source_glyph_ids=complete;font=TTFont(io.BytesIO(data));family+=' full'
            # Preserve the font's own family for existing TrueType/OpenType fonts.
            order=font.getGlyphOrder()
            for rec in font['name'].names:
                if rec.nameID in (1,3,4,6,16):
                    value=family.replace(' ','') if rec.nameID==6 else family
                    rec.string=value.encode(rec.getEncoding(),errors='replace')
            encoded=io.BytesIO();font.save(encoded);data=encoded.getvalue()
        else:return None
        if not data:return None
        font=TTFont(io.BytesIO(data));cmap=dict(font.getBestCmap() or {})
        # Some embedded subset fonts expose glyphs without Unicode entries.
        # Preserve their actual outlines using private-use aliases, including
        # bullets and large mathematical bracket components.
        synthetic_space=None
        if 32 not in cmap and 'glyf' in font:
            synthetic_space='ecSpace';font['glyf'][synthetic_space]=TTGlyphPen(None).glyph()
            font['hmtx'][synthetic_space]=(round(font['head'].unitsPerEm*.25),0)
            order=order+[synthetic_space];font.setGlyphOrder(order);cmap[32]=synthetic_space
        glyph_codes={i:(0xE000+i if i<0x1900 else 0xF0000+i) for i in range(len(order)) if i<0xFFFE}
        preferred_unicode={i:chr(MATH_UNICODE[g]) for i,g in enumerate(order) if g in MATH_UNICODE and cmap.get(MATH_UNICODE[g])==g}
        aliases=CmapSubtable.newSubtable(12);aliases.platformID=3;aliases.platEncID=10;aliases.language=0
        aliases.cmap=dict(cmap);aliases.cmap.update({code:order[i] for i,code in glyph_codes.items()})
        font['cmap'].tables=[t for t in font['cmap'].tables if not (t.platformID==3 and t.platEncID==10)]+[aliases]
        encoded=io.BytesIO();font.save(encoded);data=encoded.getvalue();cmap=aliases.cmap
        upem=font['head'].unitsPerEm;hhea=font['hhea']
        return {'source':plain,'family':family,'data':data,'ascent':hhea.ascent/upem-baseline_shift,
                'descent':hhea.descent/upem,'cmap':set(cmap),'glyph_order':order,'glyph_codes':glyph_codes,
                'preferred_unicode':preferred_unicode,'extra_cmap':{},'space_ratios':[],'synthetic_space':synthetic_space,'size_factor':factor,
                'source_glyph_ids':source_glyph_ids,
                'extraction_names':extraction_names,
                'glyph_advances':{i:font['hmtx'][g][0]/upem for i,g in enumerate(order)},
                'advances':{c:font['hmtx'][g][0]/upem for c,g in cmap.items()}}
    except Exception:
        return None

def positioned_text(text, family, size, x, baseline, width, color, shape_id, ascent=.8, bold=False, italic=False, spacing=0):
    top=max(0,baseline-size*ascent)
    height=max(12,size*1.8)
    # Let a line grow to its right while preserving its PDF origin. It remains a
    # single editable Word text run, rather than isolated character objects.
    style=f'position:absolute;margin-left:{x:.3f}pt;margin-top:{top:.3f}pt;width:{max(width+10,15):.3f}pt;height:{height:.3f}pt;z-index:2;mso-position-horizontal-relative:page;mso-position-vertical-relative:page;mso-wrap-style:none'
    return f'''<w:r><w:pict><v:rect id="ec-text-{shape_id}" style="{style}" filled="f" stroked="f"><v:textbox inset="0,0,0,0" style="mso-fit-shape-to-text:t"><w:txbxContent><w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="{round(size*20)}" w:lineRule="exact"/><w:contextualSpacing/><w:widowControl w:val="0"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii="{xml(family)}" w:hAnsi="{xml(family)}" w:eastAsia="{xml(family)}"/><w:sz w:val="{round(size*2)}"/><w:szCs w:val="{round(size*2)}"/><w:color w:val="{color:06X}"/>{'<w:b/>' if bold else ''}{'<w:i/>' if italic else ''}<w:kern w:val="0"/><w:spacing w:val="{round(spacing*20)}"/><w14:ligatures w14:val="standardContextual"/></w:rPr><w:t xml:space="preserve">{xml(text)}</w:t></w:r></w:p></w:txbxContent></v:textbox></v:rect></w:pict></w:r>'''

def artwork_xml(rid,x,y,width,height,shape_id):
    style=f'position:absolute;margin-left:{x:.3f}pt;margin-top:{y:.3f}pt;width:{width:.3f}pt;height:{height:.3f}pt;z-index:1;mso-position-horizontal-relative:page;mso-position-vertical-relative:page'
    return f'<w:r><w:pict><v:rect id="ec-art-{shape_id}" style="{style}" filled="f" stroked="f"><v:imagedata r:id="{rid}" o:title="PDF artwork without text"/></v:rect></w:pict></w:r>'

def section(width,height):
    if max(width,height)>1584:raise ValueError('This PDF page exceeds Word’s 22-inch page limit.')
    return f'<w:sectPr><w:type w:val="nextPage"/><w:pgSz w:w="{round(width*20)}" w:h="{round(height*20)}"/><w:pgMar w:top="0" w:right="0" w:bottom="0" w:left="0" w:header="0" w:footer="0" w:gutter="0"/></w:sectPr>'

def convert(source,destination):
    # The six-letter subset prefix is part of the font's identity. Removing it
    # merges unrelated glyph indexes from different subsets on the same page.
    pymupdf.TOOLS.set_subset_fontnames(True)
    document=pymupdf.open(source)
    if document.needs_pass:raise ValueError('Password-protected PDFs are not supported.')
    if not 0<len(document)<=100:raise ValueError('Use a PDF with 1–100 pages.')
    files={};fonts={};page_data=[];font_coverage={};text_count=0;shape_id=1
    for page in document:
        page.remove_rotation()
        if max(page.rect.width,page.rect.height)>1584:raise ValueError('This PDF page exceeds Word’s 22-inch page limit.')
        records={f[3]:f for f in page.get_fonts()}
        font_keys={}
        for name,record in records.items():
            key=str(record[0])+':'+name;font_keys[name]=key
            if key not in fonts:fonts[key]=make_font(document,record)
        # Extraction can use the binary's PostScript/family name instead of the
        # PDF BaseFont. Keep subset prefixes and accept only unambiguous aliases.
        aliases={}
        for name in records:
            key=font_keys[name];font=fonts[key]
            names=font['extraction_names'] if font else {name}
            for alias in names | {re.sub(r'^[A-Z]{6}\+','',n) for n in names}:
                aliases.setdefault(alias,set()).add(key)
        for alias,keys in aliases.items():
            if len(keys)==1:font_keys.setdefault(alias,next(iter(keys)))
        raw=page.get_text('rawdict',flags=pymupdf.TEXT_PRESERVE_LIGATURES|pymupdf.TEXT_PRESERVE_WHITESPACE)
        trace={}
        for run in page.get_texttrace():
            for code,glyph,origin,bbox in run['chars']:
                if glyph>=0:
                    trace[(run['font'],round(origin[0],2),round(origin[1],2),code)]=glyph
        spans=[]
        for block in raw['blocks']:
            for line in block.get('lines',[]):
                for span in line['spans']:
                    if not span.get('chars'):continue
                    span['_font_key']=font_keys.get(span['font'],span['font'])
                    for char in span['chars']:
                        font=fonts.get(span['_font_key'])
                        gid=trace.get((span['font'],round(char['origin'][0],2),round(char['origin'][1],2),ord(char['c'])))
                        if font and font['source_glyph_ids'] is not None:
                            gid=font['source_glyph_ids'].get(gid)
                        if font and (char['c']=='\ufffd' or 0xE000<=ord(char['c'])<=0xF8FF) and gid in font['preferred_unicode']:
                            char['c']=font['preferred_unicode'][gid]
                        if char['c']=='\ufffd':
                            if font and gid in font['glyph_codes']:char['c']=chr(font['glyph_codes'][gid])
                            else:raise ValueError(f'Couldn’t reconstruct a character on page {page.number+1}. No Word file was saved.')
                        if font and ord(char['c']) not in font['cmap'] and not char['c'].isspace():
                            if gid is not None and 0<=gid<len(font['glyph_order']):
                                # Keep the real Unicode text. PDF font subsets often
                                # have no usable cmap even though the PDF does.
                                code=ord(char['c']);font['extra_cmap'][code]=font['glyph_order'][gid]
                                font['cmap'].add(code);font['advances'][code]=font['glyph_advances'][gid]
                            else:raise ValueError(f'Couldn’t reconstruct a character on page {page.number+1}. No Word file was saved.')
                        if font and char['c']==' ':
                            width=(char['bbox'][2]-char['bbox'][0])/max(1,span['size'])
                            if .1<width<.8:font['space_ratios'].append(width)
                    previous=spans[-1] if spans else None
                    same=previous and all(previous.get(k)==span.get(k) for k in ('_font_key','size','color'))
                    horizontal=all(abs(c['origin'][1]-span['origin'][1])<.2 for c in span['chars'])
                    if same and horizontal and abs(previous['origin'][1]-span['origin'][1])<.2 and -.5<=span['origin'][0]-previous['bbox'][2]<max(1,span['size']*.15):
                        previous['chars'].extend(span['chars'])
                        previous['bbox']=(min(previous['bbox'][0],span['bbox'][0]),min(previous['bbox'][1],span['bbox'][1]),max(previous['bbox'][2],span['bbox'][2]),max(previous['bbox'][3],span['bbox'][3]))
                    else:
                        # Vertical math constructions must retain the original
                        # position of each glyph instead of becoming one row.
                        if not horizontal:
                            for char in span['chars']:
                                child=dict(span,chars=[char],origin=char['origin'],bbox=char['bbox']);spans.append(child)
                        else:spans.append(span)
        if not spans and page.get_images():raise ValueError(f'Page {page.number+1} has no selectable text. Editable conversion needs OCR for scanned pages; use an OCR tool first.')
        # Remove actual PDF text objects from the artwork, preserving lines,
        # diagrams, colors and embedded images. Never cover text with a screenshot.
        page.add_redact_annot(page.rect*page.derotation_matrix,fill=False)
        page.apply_redactions(images=0,graphics=0,text=0)
        if page.get_text().strip():raise ValueError('Could not separate PDF text from artwork safely.')
        pix=page.get_pixmap(matrix=pymupdf.Matrix(2,2),alpha=False)
        image=Image.frombytes('RGB',(pix.width,pix.height),pix.samples)
        difference=ImageChops.difference(image,Image.new('RGB',image.size,'white'))
        bbox=difference.convert('L').point(lambda v:255 if v>6 else 0).getbbox()
        art=None
        if bbox:
            bbox=(max(0,bbox[0]-2),max(0,bbox[1]-2),min(image.width,bbox[2]+2),min(image.height,bbox[3]+2))
            stream=io.BytesIO();image.crop(bbox).save(stream,format='PNG')
            name=f'artwork-{page.number+1}.png';files['word/media/'+name]=stream.getvalue()
            art=(name,bbox[0]/2,bbox[1]/2,(bbox[2]-bbox[0])/2,(bbox[3]-bbox[1])/2)
        page_data.append((page.rect.width,page.rect.height,spans,art))
    font_xml=[];font_rels=[]
    for number,(name,font) in enumerate(fonts.items(),1):
        if not font:continue
        if font['extra_cmap'] or (font['synthetic_space'] and font['space_ratios']):
            embedded=TTFont(io.BytesIO(font['data']))
            for table in embedded['cmap'].tables:
                if table.isUnicode():
                    table.cmap.update({code:glyph for code,glyph in font['extra_cmap'].items() if code<=0xFFFF or table.format==12})
            if font['synthetic_space'] and font['space_ratios']:
                values=sorted(font['space_ratios']);ratio=values[len(values)//2]
                embedded['hmtx'][font['synthetic_space']]=(round(embedded['head'].unitsPerEm*ratio),0)
                font['advances'][32]=ratio
            encoded=io.BytesIO();embedded.save(encoded);font['data']=encoded.getvalue()
        guid=uuid.uuid4();key=guid.bytes[::-1];encoded=bytearray(font['data'])
        for i in range(min(32,len(encoded))):encoded[i]^=key[i%16]
        files[f'word/fonts/font{number}.odttf']=encoded
        font_xml.append(f'<w:font w:name="{xml(font["family"])}"><w:family w:val="auto"/><w:embedRegular r:id="font{number}" w:fontKey="{{{str(guid).upper()}}}" w:subsetted="true"/></w:font>')
        font_rels.append(f'<Relationship Id="font{number}" Type="{R}/font" Target="fonts/font{number}.odttf"/>')
    document_rels=[f'<Relationship Id="fonts" Type="{R}/fontTable" Target="fontTable.xml"/>']
    paragraphs=[];last_section='';warn=[]
    for index,(width,height,spans,art) in enumerate(page_data):
        last_section=section(width,height)
        ppr='<w:spacing w:before="0" w:after="0" w:line="20" w:lineRule="exact"/>'+(last_section if index<len(page_data)-1 else '')
        content=[]
        if art:
            name,x,y,w,h=art;rid=f'art{index+1}'
            document_rels.append(f'<Relationship Id="{rid}" Type="{R}/image" Target="media/{name}"/>')
            content.append(artwork_xml(rid,x,y,w,h,shape_id));shape_id+=1
        for span in spans:
            name=re.sub(r'^[A-Z]{6}\+','',span['font']);font=fonts.get(span['_font_key'])
            chars=span['chars'];size=span['size'];pieces=[];prev=None
            for char in chars:
                if prev:
                    gap=char['origin'][0]-prev['bbox'][2]
                    if gap>size*.13 and not prev['c'].isspace() and not char['c'].isspace():pieces.append(' ')
                pieces.append(char['c']);prev=char
            text=''.join(pieces)
            if not text.strip():continue
            text_count+=len(text)
            family=font['family'] if font else ('Times New Roman' if re.match('CM|SF',name) else name)
            unsupported={c for c in text if not c.isspace()}-set(chr(c) for c in font['cmap']) if font else set()
            if unsupported:
                font_coverage.setdefault(name,set()).update(unsupported)
            x,baseline=span['origin'];bbox=span['bbox']
            render_size=size*(font['size_factor'] if font else 1)
            natural=sum(font['advances'].get(ord(c),.5) for c in text)*(round(render_size*2)/2) if font else bbox[2]-x
            spacing=max(-.5,min(.5,((bbox[2]-x)-natural)/max(1,len(text)-1))) if len(text)>1 else 0
            content.append(positioned_text(text,family,render_size,x,baseline,bbox[2]-x,span.get('color',0),shape_id,
                ascent=font['ascent'] if font else span.get('ascender',.8),
                bold=not font and bool(span.get('flags',0)&16),italic=not font and bool(span.get('flags',0)&2),spacing=spacing))
            shape_id+=1
        paragraphs.append(f'<w:p><w:pPr>{ppr}</w:pPr>{"".join(content)}</w:p>')
    namespaces=f'xmlns:w="{W}" xmlns:r="{R}" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"'
    files['word/document.xml']=DECL+f'<w:document {namespaces}><w:body>{"".join(paragraphs)}{last_section}</w:body></w:document>'
    files['word/fontTable.xml']=DECL+f'<w:fonts xmlns:w="{W}" xmlns:r="{R}">{"".join(font_xml)}</w:fonts>'
    files['word/_rels/fontTable.xml.rels']=DECL+f'<Relationships xmlns="{REL}">{"".join(font_rels)}</Relationships>'
    files['word/_rels/document.xml.rels']=DECL+f'<Relationships xmlns="{REL}">{"".join(document_rels)}</Relationships>'
    files['_rels/.rels']=DECL+f'<Relationships xmlns="{REL}"><Relationship Id="doc" Type="{R}/officeDocument" Target="word/document.xml"/></Relationships>'
    files['[Content_Types].xml']=DECL+'''<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Default Extension="odttf" ContentType="application/vnd.openxmlformats-officedocument.obfuscatedFont"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/fontTable.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml"/></Types>'''
    if not text_count:raise ValueError('No selectable text found. Editable conversion needs OCR for this PDF.')
    if font_coverage:raise ValueError('Some PDF symbols could not be preserved with their original font. Conversion stopped instead of saving substituted symbols.')
    with zipfile.ZipFile(destination,'w',zipfile.ZIP_DEFLATED) as archive:
        for name,data in files.items():archive.writestr(name,data)
    return {'pages':len(page_data),'editable_characters':text_count,'text_boxes':shape_id-1,'unmapped_font_characters':{k:''.join(sorted(v)) for k,v in font_coverage.items()}}

def convert_flowing(source,destination):
    from flowing_word import convert as native_paragraphs
    return native_paragraphs(source,destination)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("destination")
    parser.add_argument("--mode", choices=["layout", "flowing", "reduce-size"], default="flowing")
    args = parser.parse_args()
    try:
        if args.mode == "reduce-size":
            from reduce_size import reduce_size
            reduce_size(Path(args.source), Path(args.destination))
        else:
            convert_word = convert if args.mode == "layout" else convert_flowing
            print(json.dumps(convert_word(args.source, args.destination), ensure_ascii=False))
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
