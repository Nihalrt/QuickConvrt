"""Regression tests for PDF font identities and editable ligature reconstruction."""
import io
from pathlib import Path
import tempfile
import unittest
import uuid
from zipfile import ZipFile
from xml.etree import ElementTree as ET

import pymupdf
from fontTools import subset
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
import pdf_editable as engine

NS={'w':engine.W,'r':engine.R}


def fixture_font(name,letters):
    builder=FontBuilder(1000,isTTF=True)
    order=['.notdef']+list(letters)
    builder.setupGlyphOrder(order)
    glyphs={};metrics={}
    for i,glyph in enumerate(order):
        pen=TTGlyphPen(None)
        if i:
            pen.moveTo((40,0));pen.lineTo((200+i*40,700));pen.lineTo((400+i*40,0));pen.closePath()
        glyphs[glyph]=pen.glyph();metrics[glyph]=(500+i*40,40)
    builder.setupCharacterMap({ord(c):c for c in letters})
    builder.setupGlyf(glyphs);builder.setupHorizontalMetrics(metrics)
    builder.setupHorizontalHeader(ascent=800,descent=-200)
    builder.setupNameTable({'familyName':name,'styleName':'Regular','uniqueFontIdentifier':name,'fullName':name,'psName':name})
    builder.setupOS2(sTypoAscender=800,sTypoDescender=-200,usWinAscent=800,usWinDescent=200)
    builder.setupPost();builder.setupMaxp()
    output=io.BytesIO();builder.save(output)
    return output.getvalue()


def without_unicode_cmap(data):
    font=TTFont(io.BytesIO(data))
    table=CmapSubtable.newSubtable(4);table.platformID=3;table.platEncID=1;table.language=0;table.cmap={}
    font['cmap'].tables=[table]
    result=io.BytesIO();font.save(result)
    return result.getvalue()


class FontMappingRegression(unittest.TestCase):
    def test_same_family_subsets_keep_distinct_glyphs(self):
        with tempfile.TemporaryDirectory() as tmp:
            pdf=Path(tmp)/'subsets.pdf';docx=Path(tmp)/'subsets.docx'
            document=pymupdf.open();page=document.new_page()
            for i,letters in enumerate(('ABC','XYZ')):
                data=fixture_font(('AAAAAA','BBBBBB')[i]+'+SubsetFixture',letters)
                page.insert_font(fontname='F'+str(i),fontbuffer=data)
                page.insert_text((40,60+i*30),letters,fontname='F'+str(i),fontsize=14)
            # Match office PDF subsets that supply Unicode in /ToUnicode but
            # no usable cmap in the embedded TrueType binary.
            for record in page.get_fonts():
                font_xref=int(document.xref_get_key(record[0],'DescendantFonts')[1].split('[')[1].split()[0])
                descriptor=int(document.xref_get_key(font_xref,'FontDescriptor')[1].split()[0])
                stream=int(document.xref_get_key(descriptor,'FontFile2')[1].split()[0])
                document.update_stream(stream,without_unicode_cmap(document.xref_stream(stream)))
            document.save(pdf)
            result=engine.convert(str(pdf),str(docx))
            self.assertEqual(result['pages'],1)
            with ZipFile(docx) as archive:
                xml=ET.fromstring(archive.read('word/document.xml'))
                self.assertEqual(''.join(xml.itertext()),'ABCXYZ')
                fonts=ET.fromstring(archive.read('word/fontTable.xml'))
                self.assertEqual(len(fonts),2,'Same-family subsets must not collapse into one font')
                cmap_sets=[]
                for n,font in enumerate(fonts,1):
                    embed=font.find('w:embedRegular',NS)
                    key=uuid.UUID(embed.get('{'+engine.W+'}fontKey').strip('{}')).bytes[::-1]
                    data=bytearray(archive.read(f'word/fonts/font{n}.odttf'))
                    for i in range(32):data[i]^=key[i%16]
                    cmap_sets.append(set(TTFont(io.BytesIO(data)).getBestCmap()))
                self.assertTrue(any(set(map(ord,'ABC'))<=c and not set(map(ord,'XYZ'))<=c for c in cmap_sets))
                self.assertTrue(any(set(map(ord,'XYZ'))<=c and not set(map(ord,'ABC'))<=c for c in cmap_sets))

    def complete_fixture(self):
        complete=engine.bundled_complete_font('Carlito')
        self.assertIsNotNone(complete,'Stage the bundled office fonts before running these tests')
        font=TTFont(io.BytesIO(complete[0]))
        tool=subset.Subsetter();tool.populate(text='Fifth office efficient');tool.subset(font)
        font['cmap'].tables=[]
        return font

    def test_matching_complete_face_restores_ligature_components(self):
        recovered=engine.complete_subset_font(self.complete_fixture(),'Carlito')
        self.assertIsNotNone(recovered)
        cmap=TTFont(io.BytesIO(recovered[0])).getBestCmap()
        self.assertTrue(set(map(ord,'Fifth office efficient'))<=set(cmap))
        self.assertIn('GSUB',TTFont(io.BytesIO(recovered[0])))

    def test_similar_but_different_font_is_never_substituted(self):
        font=self.complete_fixture()
        glyph=font.getGlyphOrder()[1];advance,lsb=font['hmtx'][glyph]
        font['hmtx'][glyph]=(advance+1,lsb)
        self.assertIsNone(engine.complete_subset_font(font,'Carlito'))


if __name__=='__main__':unittest.main()
