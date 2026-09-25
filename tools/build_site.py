#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["Markdown==3.10.3"]
# ///
"""Publish the existing Typst documents as HTML/PDF, with navigation and search."""
import argparse
from html import escape, unescape
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import unquote, urlsplit
import markdown

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/site-documents'
BASE = '/sqlodin/'
REPO = 'https://github.com/insanai/sqlodin'


def title(path):
    match = re.search(r'^= (.+)$', path.read_text(), re.M)
    return match[1] if match else path.stem.replace('-', ' ').title()


def inventory():
    pages = []
    for group, folder, pattern in [('book', 'docs/book', '[0-9][0-9]_*.typ'),
                                   ('guides', 'docs/guides', '*.typ'),
                                   ('specs', 'specs', '*.typ')]:
        for path in sorted((ROOT / folder).glob(pattern)):
            if path.stem.startswith('00_'):
                continue
            pages.append(dict(source=path, title=title(path), group=group,
                              route=f'{group}/{path.stem}/'))
    registry = (ROOT / 'docs/sod/registry.typ').read_text()
    for record in re.findall(r'  \(\n(.*?)\n  \),', registry, re.S):
        fields = dict(re.findall(r'^    (\w+): "([^"]*)",', record, re.M))
        pages.append(dict(source=ROOT / fields['source'], title=f"SOD {fields['number']}: {fields['title']}",
                          group='sods', route=f"sods/{fields['number']}/", status=fields['status'],
                          summary=fields['summary']))
    pages.append(dict(source=ROOT / 'languages/python/README.md', title='Python client',
                      group='python', route='python/'))
    return pages


def navigation(pages, active):
    groups = [('book', 'The book'), ('guides', 'Practical guides'), ('python', 'Python'),
              ('sods', 'Design discussions'), ('specs', 'Specifications')]
    result = '<aside class="sidebar"><details open><summary>Documentation</summary>'
    for group, label in groups:
        result += f'<span class="group">{label}</span>'
        for page in pages:
            if page['group'] == group:
                current = ' aria-current="page"' if page['route'] == active else ''
                href = BASE + page['route']
                if active == 'book/' and group == 'book':
                    label = re.search(r'^<([\w-]+)>', page['source'].read_text(), re.M)[1]
                    href = BASE + 'book/#' + label
                result += f'<a href="{href}"{current}>{escape(page["title"])}</a>'
    return result + '</details></aside>'


def shell(heading, body, pages, route='', tools='', styles=''):
    content = (f'<div class="docs-layout">{navigation(pages, route)}<main id="main" class="reading">'
               f'{tools}<article>{body}</article></main></div>') if route else f'<main id="main" class="home">{body}</main>'
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="SQLodin: a distributed SQL database built with SQLite and Paxos. Multi-master writes, an interactive CLI, and a Python client.">
<title>{escape(heading)} · SQLodin</title>{styles}<link rel="stylesheet" href="{BASE}assets/site.css">
<script defer src="{BASE}assets/site.js"></script></head><body>
<a class="skip" href="#main">Skip to content</a><header class="nav"><a class="brand" href="{BASE}"><i aria-hidden="true">s.</i>sqlodin</a>
<nav aria-label="Main"><a href="{BASE}book/">Book</a><a href="{BASE}guides/">Guides</a><a href="{BASE}python/">Python</a><a href="{REPO}">GitHub ↗</a><button class="search-open" type="button">Search</button></nav></header>
{content}<footer class="footer"><span>Written by Vikrant Rathore, with assistance from Ronak Rathore.</span><a href="{REPO}/blob/main/LICENSE">MIT license</a></footer>
<dialog id="search-dialog" aria-labelledby="search-title"><header><strong id="search-title">Search the documentation</strong><button id="search-close" type="button" aria-label="Close search">✕</button></header>
<label for="search-query">Words or a topic</label><input id="search-query" type="search" placeholder="Try transactions, quorum, or recovery" autocomplete="off"><div id="results" aria-live="polite"></div></dialog>
</body></html>'''


def compile_typst(source, output, html=False):
    command = ['typst', 'compile', '--root', str(ROOT)]
    if html:
        command += ['--features', 'html', '--format', 'html']
    log = output.with_suffix(output.suffix + '.log')
    with log.open('w') as stream:
        result = subprocess.run(command + [str(source), str(output)], stdout=stream, stderr=stream)
    if result.returncode:
        raise SystemExit(log.read_text())


def rewrite_links(body, source, routes):
    def replace(match):
        href = unescape(match[1])
        url = urlsplit(href)
        if url.scheme or url.netloc or not url.path or href.startswith(BASE):
            return match[0]
        # Includes often refer to sibling documents relative to the included chapter.
        candidates = [(source.parent / unquote(url.path)).resolve(), (ROOT / unquote(url.path)).resolve()]
        candidates += [p for p in routes if p.name == Path(unquote(url.path)).name]
        for candidate in candidates:
            if candidate in routes:
                return f'href="{BASE}{routes[candidate]}{("#" + url.fragment) if url.fragment else ""}"'
        for candidate in candidates:
            if candidate.is_file() and candidate.is_relative_to(ROOT):
                return f'href="{REPO}/blob/main/{candidate.relative_to(ROOT)}"'
        return f'href="{REPO}/blob/main/{escape(url.path, quote=True)}"'
    return re.sub(r'href="([^"]+)"', replace, body)


class Content(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.words = []
        self.ids = set()
    def handle_starttag(self, tag, attrs):
        for key, value in attrs:
            if key == 'id':
                self.ids.add(value)
            if key in ('href', 'src') and value:
                self.links.append(value)
    def handle_data(self, data):
        self.words.append(data)


def validate(site):
    broken = []
    parsed = {}
    for path in site.rglob('*.html'):
        parser = Content(); parser.feed(path.read_text())
        parsed[path] = parser
    for path, parser in parsed.items():
        for link in parser.links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                continue
            if not url.path:
                target = path
            elif url.path.startswith(BASE):
                target = site / unquote(url.path[len(BASE):])
            else:
                target = path.parent / unquote(url.path)
            if not target.exists():
                broken.append((str(path.relative_to(site)), link))
                continue
            if target.is_dir():
                target /= 'index.html'
            if url.fragment and target in parsed and unquote(url.fragment) not in parsed[target].ids:
                broken.append((str(path.relative_to(site)), link))
    if broken:
        raise SystemExit(f'Broken site links: {broken}')
    if '<svg' not in (site / 'book/05_consensus/index.html').read_text():
        raise SystemExit('Consensus chapter lost its vector diagrams')
    print(f'PASS site links, anchors and diagrams: {len(parsed)} pages')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/site')
    args = parser.parse_args()
    site = args.output.resolve()
    if site == ROOT / 'build' or not site.is_relative_to(ROOT / 'build'):
        raise SystemExit('Use a dedicated subdirectory of build/')
    if site.exists():
        shutil.rmtree(site)
    (site / 'assets').mkdir(parents=True)
    (site / 'downloads').mkdir()
    BUILD.mkdir(parents=True, exist_ok=True)
    pages = inventory()
    routes = {p['source'].resolve(): p['route'] for p in pages}
    routes[ROOT / 'docs/book.typ'] = 'book/'
    routes[ROOT / 'docs/index.typ'] = 'guides/'
    search = []
    for asset in ('site.css', 'site.js'):
        shutil.copy2(ROOT / 'docs/site' / asset, site / 'assets' / asset)
    compile_typst(ROOT / 'docs/book.typ', site / 'downloads/sqlodin-book.pdf')
    for page in pages:
        source = page['source']
        styles = ''
        if source.suffix == '.md':
            body = markdown.markdown(source.read_text(), extensions=['fenced_code', 'tables'])
            pdf = None
        else:
            stem = page['route'].strip('/').replace('/', '-')
            wrapper = BUILD / f'{stem}.typ'
            references = ''
            if page['group'] == 'book':
                labels = {}
                for chapter in pages:
                    if chapter['group'] == 'book':
                        for label in re.findall(r'^<([\w-]+)>', chapter['source'].read_text(), re.M):
                            labels[label] = dict(url=BASE + chapter['route'] + '#' + label,
                                                 title=chapter['title'])
                reference_file = BUILD / 'book-references.json'
                reference_file.write_text(json.dumps(labels))
                references = ('#let references = json("book-references.json")\n'
                              '#show ref: it => { let key = str(it.target); '
                              'if key in references { let item = references.at(key); '
                              'link(item.url, item.title) } else { it } }\n')
            wrapper.write_text('#import "/docs/site/html.typ": web\n#show: web\n' +
                               '#set figure(kind: image, supplement: [Figure])\n' + references +
                               f'#include "/{source.relative_to(ROOT)}"\n')
            output = BUILD / f'{stem}.html'
            compile_typst(wrapper, output, html=True)
            text = output.read_text()
            body = re.search(r'<body[^>]*>(.*)</body>', text, re.S)[1]
            styles = ''.join(re.findall(r'<style[^>]*>.*?</style>', text, re.S))
            pdf = 'sqlodin-book.pdf' if page['group'] == 'book' else f'{stem}.pdf'
            if page['group'] != 'book':
                compile_typst(source, site / 'downloads' / pdf)
        body = rewrite_links(body, source, routes)
        if page['group'] == 'book':
            for label in re.findall(r'^<([\w-]+)>', source.read_text(), re.M):
                if f'id="{label}"' not in body:
                    body = f'<span id="{label}"></span>' + body
        if '<h1' not in body:
            body = re.sub(r'<(/?)h([2-6])(?=[ >])',
                          lambda m: f'<{m[1]}h{int(m[2]) - 1}', body)
        content = Content(); content.feed(body)
        search.append(dict(title=page['title'], url=BASE + page['route'],
                           text=re.sub(r'\s+', ' ', ' '.join(content.words))))
        tools = f'<div class="reader-tools"><a href="{BASE}{page["group"]}/">{page["group"].title()}</a>'
        tools += f'<a href="{REPO}/blob/main/{source.relative_to(ROOT)}">View source ↗</a>'
        if pdf:
            tools += f'<a href="{BASE}downloads/{pdf}">Download PDF ↓</a>'
        tools += '</div>'
        if page['group'] == 'book':
            chapters = [p for p in pages if p['group'] == 'book']
            i = chapters.index(page)
            body += '<nav class="pager" aria-label="Chapters">'
            for j, direction in [(i - 1, '← Previous'), (i + 1, 'Next →')]:
                if 0 <= j < len(chapters):
                    body += f'<a href="{BASE}{chapters[j]["route"]}">{direction}: {escape(chapters[j]["title"])}</a>'
            body += '</nav>'
        destination = site / page['route'] / 'index.html'
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(shell(page['title'], body, pages, page['route'], tools, styles))
        print('Built', page['route'], flush=True)
    for group, heading, intro in [
        ('guides', 'Practical guides', 'Instructions for building, connecting to, and operating SQLodin.'),
        ('sods', 'SQLodin Discussions', 'Design decisions, alternatives and implementation boundaries. Each SOD states its current status.'),
        ('specs', 'Protocol and specifications', 'Contracts, invariants and assumptions. These documents distinguish model guarantees from implementation evidence.')]:
        body = f'<p class="eyebrow">Documentation</p><h1>{heading}</h1><p>{intro}</p><ul class="page-list">'
        for page in pages:
            if page['group'] == group:
                body += f'<li><a href="{BASE}{page["route"]}">{escape(page["title"])}</a>'
                if page.get('summary'):
                    body += f'<p>{escape(page["summary"])}</p><span class="label">{escape(page["status"])}</span>'
                body += '</li>'
        body += '</ul>'
        if group == 'book':
            body += f'<p><a href="{BASE}downloads/sqlodin-book.pdf">Download the complete book as a PDF ↓</a></p>'
        (site / group / 'index.html').write_text(shell(heading, body, pages, f'{group}/'))
    # The book route is the complete reading edition, not a directory listing.
    wrapper = BUILD / 'complete-book.typ'
    wrapper.write_text('#import "/docs/site/html.typ": web\n#show: web\n'
                       '#include "/docs/book.typ"\n')
    complete = BUILD / 'complete-book.html'
    compile_typst(wrapper, complete, html=True)
    text = complete.read_text()
    body = re.search(r'<body[^>]*>(.*)</body>', text, re.S)[1]
    styles = ''.join(re.findall(r'<style[^>]*>.*?</style>', text, re.S))
    # Navigation lives beside the reading column; retain the authored introduction.
    first_heading = body.index('<h2')
    body = '<h1>The SQLodin book</h1><p class="lead">Use, design and evidence.</p>' + body[first_heading:]
    body = re.sub(r'<h2[^>]*>Contents</h2>', '', body)
    body = re.sub(r'<nav[^>]*role="doc-toc"[^>]*>.*?</nav>', '', body, flags=re.S)
    body = rewrite_links(body, ROOT / 'docs/book.typ', routes)
    tools = (f'<div class="reader-tools"><span>Complete reading edition</span>'
             f'<a href="{BASE}downloads/sqlodin-book.pdf">Download PDF ↓</a></div>')
    (site / 'book/index.html').write_text(shell('The SQLodin book', body, pages, 'book/', tools, styles))
    (site / 'index.html').write_text(shell('A distributed SQL database', (ROOT / 'docs/site/index.html').read_text(), pages))
    (site / 'search.json').write_text(json.dumps(search))
    (site / '.nojekyll').touch()
    validate(site)


if __name__ == '__main__':
    main()
