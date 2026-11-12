"""Meaningful conversion checks independent of any private reference document."""
import io
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile
import pymupdf
from docx import Document
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from lxml import etree
from fontTools.ttLib import TTFont
import uuid
import flowing_word as engine

NS={'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}

class FlowingWordRegression(unittest.TestCase):
    def test_exported_text_decorations_and_indented_paragraph_stay_editable(self):
        with tempfile.TemporaryDirectory() as tmp:
            source=Path(tmp)/'formatted.pdf';target=Path(tmp)/'formatted.docx'
            size=11;left=72;right=540
            def width(text):return pymupdf.get_text_length(text,fontname='helv',fontsize=size)

            with pymupdf.open() as pdf:
                page=pdf.new_page(width=612,height=792)
                date='November 11, 2026'
                page.insert_text((right-width(date),88),date,fontsize=size)
                first='The first line is indented.'
                while width(first+' editable words')<right-left-36:
                    first+=' editable words'
                continuation='The second line belongs to the same paragraph.'
                page.insert_text((left+36,111),first,fontsize=size)
                page.insert_text((left,124),continuation,fontsize=size)
                line='An underlined word and highlighted text remain editable.'
                for start,end,top,bottom,fill in (
                    ('An ','An underlined word',149.6,150.4,(0,0,0)),
                    ('An underlined word and ','An underlined word and highlighted text',138,151,(1,.95,.65)),
                ):
                    page.draw_rect(pymupdf.Rect(left+width(start),top,left+width(end),bottom),color=None,fill=fill)
                page.insert_text((left,148),line,fontsize=size)
                pdf.save(source)

            self.assertEqual(engine.convert(str(source),str(target))['engine'],'native-flow')
            with ZipFile(target) as archive:
                root=etree.fromstring(archive.read('word/document.xml'))
            date_node,body,decorated=root.xpath('//w:body/w:p',namespaces=NS)
            self.assertTrue(date_node.xpath('./w:pPr/w:jc[@w:val="right"]',namespaces=NS))
            self.assertTrue(body.xpath('./w:pPr/w:ind[@w:firstLine="720"]',namespaces=NS))
            self.assertEqual(''.join(body.xpath('.//w:t/text()',namespaces=NS)),first+' '+continuation)
            self.assertFalse(body.xpath('.//w:br',namespaces=NS))
            self.assertEqual(decorated.xpath('./w:r[w:rPr/w:u]/w:t/text()',namespaces=NS),['underlined word'])
            self.assertEqual(decorated.xpath('./w:r[w:rPr/w:shd]/w:t/text()',namespaces=NS),['highlighted text'])

    def test_short_side_labels_do_not_create_columns_and_links_remain_visible(self):
        with tempfile.TemporaryDirectory() as tmp:
            source=Path(tmp)/'test.pdf';target=Path(tmp)/'test.docx'
            pdf=pymupdf.open();page=pdf.new_page(width=612,height=792)
            page.insert_text((40,55),'Native paragraph fixture',fontsize=16)
            page.insert_text((40,80),'Role title',fontsize=11)
            page.insert_text((455,80),'West coast',fontsize=11)
            page.insert_text((40,96),'Employer'+' '*105+'2024 - 2026',fontsize=11)
            heading=pymupdf.Point(40,112)
            page.insert_text(heading,'Stretched heading',fontsize=11,morph=(heading,pymupdf.Matrix(1.25,1)))
            text='A complete paragraph can be edited and reflowed in Word. '*8
            page.insert_textbox(pymupdf.Rect(40,125,565,230),text,fontsize=11)
            page.insert_text((40,260),'Visible hyperlink',fontsize=11)
            page.insert_link({'kind':pymupdf.LINK_URI,'from':pymupdf.Rect(38,248,130,263),'uri':'https://example.com/'})
            page.draw_rect(pymupdf.Rect(40,261,122,261.6),color=None,fill=(0,0,1))
            pdf.save(source)
            result=engine.convert(str(source),str(target));self.assertEqual(result['engine'],'native-flow')
            with ZipFile(target) as z:
                x=etree.fromstring(z.read('word/document.xml'))
                self.assertFalse(x.xpath('//w:txbxContent|//w:framePr',namespaces=NS))
                self.assertFalse(x.xpath('//w:cols[@w:num="2"]',namespaces=NS))
                self.assertTrue(x.xpath('//w:tabs/w:tab[@w:val="right"]',namespaces=NS))
                self.assertTrue(x.xpath('//w:p[w:r/w:t="Employer"][w:r/w:tab][w:r/w:t="2024 - 2026"]',namespaces=NS))
                self.assertTrue(x.xpath('//w:r[w:t="Stretched heading"]/w:rPr/w:w[@w:val="125"]',namespaces=NS))
                self.assertTrue(x.xpath('//w:hyperlink/w:r/w:t[text()="Visible hyperlink"]',namespaces=NS))
                self.assertFalse(x.xpath('//w:r/w:hyperlink',namespaces=NS))
                body_paragraphs=x.xpath('//w:body/w:p',namespaces=NS)
                paragraph=next(p for p in body_paragraphs if ''.join(p.xpath('.//w:t/text()',namespaces=NS)).startswith('A complete'))
                self.assertGreater(len(''.join(paragraph.xpath('.//w:t/text()',namespaces=NS))),300)
                self.assertFalse(paragraph.xpath('.//w:br',namespaces=NS),'Wrapped lines must remain one reflowable paragraph')

    def test_wrapped_bullet_is_one_native_list_item_with_hanging_indent(self):
        with tempfile.TemporaryDirectory() as tmp:
            source=Path(tmp)/'list.pdf';target=Path(tmp)/'list.docx'
            pdf=pymupdf.open();page=pdf.new_page(width=612,height=792)
            page.insert_text((40,40),'List fixture',fontsize=14)
            # Base-14 fonts expose this bullet as a selectable middle dot. Use
            # an explicit supported Unicode bullet font from the bundled office engine.
            font=Path(__file__).parent.parent/'build/office-engine/LibreOfficeDev.app/Contents/Resources/fonts/truetype/LiberationSans-Regular.ttf'
            self.assertTrue(font.is_file())
            page.insert_font(fontname='ListFont',fontfile=str(font))
            page.insert_text((40,80),'•',fontname='ListFont',fontsize=10)
            content='A native bullet wraps naturally when the available space is filled with editable words. '
            page.insert_textbox(pymupdf.Rect(52,70.9,560,115),content*2,fontname='ListFont',fontsize=10)
            pdf.save(source)
            engine.convert(str(source),str(target))
            with ZipFile(target) as z:
                x=etree.fromstring(z.read('word/document.xml'))
                items=x.xpath('//w:p[w:pPr/w:numPr]',namespaces=NS)
                self.assertEqual(len(items),1)
                self.assertGreater(len(''.join(items[0].xpath('.//w:t/text()',namespaces=NS))),100)
                self.assertGreater(int(items[0].xpath('./w:pPr/w:ind/@w:hanging',namespaces=NS)[0]),0)
                self.assertNotIn('•',''.join(items[0].xpath('.//w:t/text()',namespaces=NS)))

    def test_incomplete_and_boxed_results_are_rejected(self):
        doc=Document();doc.add_paragraph('Partial content');buffer=io.BytesIO();doc.save(buffer)
        with self.assertRaisesRegex(ValueError,'missing'):engine.validate(buffer.getvalue(),'Partial content with a missing sentence')
        doc.paragraphs[0]._p.append(OxmlElement('w:txbxContent'));buffer=io.BytesIO();doc.save(buffer)
        with self.assertRaisesRegex(ValueError,'text boxes'):engine.validate(buffer.getvalue(),'Partial content')

    def test_tight_paragraph_boundaries_do_not_accumulate_leading(self):
        groups=[]
        for first in (80,103,126):
            groups.append([{'baseline':y,'bbox':(40,y-8.1,560,y+2),'size':9} for y in (first,first+12)])
        geometry=engine.paragraph_geometry(groups)
        for group,(top,height,rises) in zip(groups,geometry):
            for i,row in enumerate(group):
                self.assertAlmostEqual(top+(i+.8)*height-rises[i]*.5,row['baseline'],delta=.026)
        for group,(top,height,_),(next_top,_,_) in zip(groups,geometry,geometry[1:]):
            self.assertLessEqual(top+len(group)*height,next_top+.025)
        self.assertLess(geometry[0][1],12,'Tight paragraph boundaries must fit without negative spacing')

    def test_private_symbol_bullets_are_unicode_and_have_an_embedded_font(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp=Path(tmp);source=tmp/'symbols.pdf';target=tmp/'symbols.docx'
            font_path=Path(__file__).parent.parent/'build/office-engine/LibreOfficeDev.app/Contents/Resources/fonts/truetype/opens___.ttf'
            font=TTFont(font_path)
            for cmap in font['cmap'].tables:
                if cmap.isUnicode() and 0x2022 in cmap.cmap:cmap.cmap[0xf0b7]=cmap.cmap.pop(0x2022)
            private_font=tmp/'private.ttf';font.save(private_font)
            pdf=pymupdf.open();page=pdf.new_page();page.insert_font(fontname='SymbolFixture',fontfile=str(private_font))
            page.insert_text((40,80),'\uf0b7',fontname='SymbolFixture',fontsize=10)
            page.insert_text((52,80),'Editable bullet content',fontsize=10);pdf.save(source)
            engine.convert(str(source),str(target))
            with ZipFile(target) as z:
                numbering=etree.fromstring(z.read('word/numbering.xml'))
                self.assertTrue(numbering.xpath('//w:lvlText[@w:val="•"]',namespaces=NS))
                table=etree.fromstring(z.read('word/fontTable.xml'))
                entry=table.xpath('//w:font[starts-with(@w:name,"EC Bullet ")]/w:embedRegular',namespaces=NS)[0]
                key=uuid.UUID(entry.get(qn('w:fontKey'))).bytes[::-1]
                encoded=bytearray(z.read('word/fonts/ec-bullet-1.odttf'))
                for i in range(32):encoded[i]^=key[i%16]
                embedded=TTFont(io.BytesIO(encoded))
                self.assertIn(0x2022,embedded.getBestCmap())
                for name in ('word/document.xml','word/numbering.xml'):
                    root=etree.fromstring(z.read(name))
                    for rpr in root.xpath('//w:rPr[w:position and w:sz]',namespaces=NS):
                        self.assertLess(rpr.index(rpr.find(qn('w:position'))),rpr.index(rpr.find(qn('w:sz'))))

if __name__=='__main__':unittest.main()
