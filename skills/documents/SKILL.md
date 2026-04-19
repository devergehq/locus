---
id: documents
name: Documents
description: Read, write, convert, and analyze documents — PDF, DOCX, XLSX, PPTX with format conversion and content extraction.
triggers:
  - document
  - process file
  - create document
  - convert format
  - extract text
  - PDF
  - DOCX
  - Word
  - Excel
  - spreadsheet
  - PowerPoint
  - presentation
tags:
  - documents
  - conversion
  - extraction
requires:
  delegation: false
---

# Documents

Document processing framework for reading, writing, converting, and analyzing common document formats.

## Supported Formats

| Format | Read | Write | Convert |
|--------|------|-------|---------|
| PDF | Extract text, tables, forms | Create, merge, split, watermark | To/from images, DOCX |
| DOCX | Full content extraction | Create with formatting, tables | To/from PDF, markdown |
| XLSX | Read cells, formulas, sheets | Create workbooks, formulas | To/from CSV, TSV |
| PPTX | Extract slides, notes | Create presentations | To/from PDF |
| Markdown | Native | Native | To/from all above |

## Workflows

### Extract
Pull text, tables, or structured data from a document. Handles multi-page PDFs, complex DOCX layouts, and multi-sheet workbooks.

### Create
Generate a new document from content. Supports templates, styling, and format-specific features (tracked changes in DOCX, formulas in XLSX, slide layouts in PPTX).

### Convert
Transform between formats while preserving as much structure as possible.

### Analyze
Examine document structure, extract metadata, summarise content, or compare versions.
