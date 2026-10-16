#!/usr/bin/env python3
"""Independent geometric acceptance checks and an SVG gallery from iOS output."""
import argparse, collections, html, json, math, pathlib, sys, re
from shapely.geometry import Polygon, Point, LineString
from shapely.ops import unary_union
from shapely import points as make_points, covers as shape_covers, prepare

COLORS = {True: dict(background='#182128',casing='#42434A',surface='#26282D',paint='#B8C6CB'),
          False: dict(background='#D5E3CF',casing='#D5D3CF',surface='#E8E9EC',paint='#FFFFFF')}
KINDS=['casing','surface','junction','gore','edge','separator','center','sharedBoundary','arrow']


def audit(scene):
    problems=[]
    if scene.get('error'): problems.append('Błąd budowy: '+scene['error'])
    if scene.get('expectedNormalized') is not None and scene['normalizedRoads']!=scene['expectedNormalized']:
        problems.append(f"Niezgodna obsługa źródła: {scene['normalizedRoads']}/{scene['expectedNormalized']}")
    if scene.get('expectedMarkingsMinimum') is not None and scene.get('junctionMarkings',0)<scene['expectedMarkingsMinimum']:
        problems.append('Brak ciągłości zgodnych separatorów')
    if scene.get('expectedJunctions') is not None and scene.get('junctions') != scene['expectedJunctions']:
        problems.append(f"Brak węzła: {scene.get('junctions',0)}/{scene['expectedJunctions']}")
    surfaces=collections.defaultdict(list)
    invalid=0
    for graphic in scene['graphics']:
        if graphic['kind']=='surface':
            polygon=Polygon(graphic['points'],graphic.get('holes',[]))
            if not polygon.is_valid: invalid+=1
            elif not polygon.is_empty: surfaces[graphic['level']].append(polygon)
    if invalid: problems.append(f'Niepoprawne wielokąty: {invalid}')
    if scene.get('family')=='rondo':
        match=re.search(r'r=([0-9.]+) m · ([0-9]+) pasów',scene['title'])
        if match and float(match[1]) > int(match[2])*3.2/2+.2:
            if any(p.covers(Point(0,0)) for polygons in surfaces.values() for p in polygons):
                problems.append('Zalana wyspa ronda')
    uncovered=0;total=0;missing=[]
    bounds=scene.get('bounds',[-1000,1000,-1000,1000])
    for level in set(s['level'] for s in scene.get('spine',[])):
        union=unary_union(surfaces.get(level,[])).buffer(.08)
        prepare(union)
        for spine in scene.get('spine',[]):
            if spine['level'] != level or not spine['checks']:continue
            checks=[p for p in spine['checks'] if bounds[0]<=p[0]<=bounds[1] and bounds[2]<=p[1]<=bounds[3]]
            if not checks:continue
            mask=shape_covers(union,make_points(checks))
            total+=len(checks);uncovered+=int((~mask).sum())
            if not mask.all(): missing.extend(p for p,covered in zip(checks,mask) if not covered)
    if uncovered:problems.append(f'Niepokryta oś: {uncovered}/{total} próbek')
    if scene.get('family')=='rozwidlenie' and len(scene.get('spine',[]))==3:
        # Independent analytic envelopes of the two outgoing fixture branches.
        a,b=scene['spine'][1:]
        overlap=LineString(a['points']).buffer(a['width']/2,cap_style=2).intersection(
            LineString(b['points']).buffer(b['width']/2,cap_style=2)).buffer(-.2)
        overlap=overlap.difference(Point(a['points'][0]).buffer(6))
        if not overlap.is_empty:
            conflict=sum(LineString(g['points']).intersection(overlap).length for g in scene['graphics']
                if g['kind']=='separator' and not g['polygon'] and len(g['points'])>1)
            if conflict>.5:problems.append(f'Oznaczenia w nakładających się odnogach: {conflict:.1f} m')
    return dict(problems=problems,uncovered=uncovered,checks=total,missing=missing)


def picture(scene, result, dark=True, diagnostics=False):
    palette=COLORS[dark]
    all_points=[p for s in scene.get('spine',[]) for p in s['points']]
    if not all_points:all_points=[[0,0],[1,1]]
    xs=[p[0] for p in all_points];ys=[p[1] for p in all_points]
    cx=(min(xs)+max(xs))/2;cy=(min(ys)+max(ys))/2
    extent=max(110,max(xs)-min(xs)+30,max(ys)-min(ys)+30)
    if scene.get('real') and scene.get('bounds'):
        bounds=scene['bounds'];cx=0;cy=0;extent=max(bounds[1]-bounds[0],bounds[3]-bounds[2])*1.05
    scale=384/extent
    def xy(point):return ((point[0]-cx)*scale+192,192-(point[1]-cy)*scale)
    def path(points,close=False):
        if not points:return ''
        mapped=[xy(p) for p in points]
        return 'M'+' L'.join(f'{x:.3f},{y:.3f}' for x,y in mapped)+('Z' if close else '')
    output=[f"<svg xmlns='http://www.w3.org/2000/svg' width='384' height='384' viewBox='0 0 384 384'><rect width='384' height='384' fill='{palette['background']}'/>"]
    for level in sorted(set(g['level'] for g in scene['graphics'])):
        for kind in KINDS:
            for g in scene['graphics']:
                if g['kind']!=kind or g['level']!=level:continue
                opacity=g.get('opacity',1)
                if g['polygon']:
                    color=palette.get(kind,palette['paint'])
                    if kind=='junction':opacity*=.035
                    if kind=='gore':opacity*=.32
                    d=path(g['points'],True)+''.join(path(h,True) for h in g.get('holes',[]))
                    output.append(f"<path d='{d}' fill='{color}' fill-rule='evenodd' opacity='{opacity:.3f}'/>")
                elif kind!='arrow':
                    dash=" stroke-dasharray='5 7'" if kind not in ['edge'] else ''
                    output.append(f"<path d='{path(g['points'])}' fill='none' stroke='{palette['paint']}' stroke-width='{.9 if kind=='edge' else 1.2}' opacity='{opacity:.3f}' stroke-linecap='round' stroke-linejoin='round'{dash}/>")
    if diagnostics:
        for s in scene.get('spine',[]):output.append(f"<path d='{path(s['points'])}' fill='none' stroke='#6BD7FF' stroke-width='.5' opacity='.6'/>")
        for p in result['missing'][:512]:
            x,y=xy(p);output.append(f"<circle cx='{x:.3f}' cy='{y:.3f}' r='2' fill='#FF475C'/>")
    output.append('</svg>')
    return ''.join(output)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('folder',type=pathlib.Path);parser.add_argument('--only',nargs='*');parser.add_argument('--arrows-only',action='store_true');parser.add_argument('--include',type=pathlib.Path)
    args=parser.parse_args();folder=args.folder
    (folder/'images').mkdir(exist_ok=True)
    rows=json.loads((folder/'audit.json').read_text()) if args.arrows_only and (folder/'audit.json').exists() else []
    rows=[row for row in rows if not row.get('arrow')]
    files=sorted((folder/'geometry').glob('*.json'))
    if args.arrows_only: files=[]
    for index,p in enumerate(files):
        if p.name in ['summary.json','arrow-glyphs.json']:continue
        if args.only and p.stem not in args.only:continue
        scene=json.loads(p.read_text());result=audit(scene)
        row={k:scene[k] for k in ['id','family','title','real']};row.update({k:result[k] for k in ['problems','uncovered','checks']})
        row.update(milliseconds=scene.get('milliseconds'),features=scene.get('features'),vertices=scene.get('vertices'))
        rows.append(row)
        for dark,name in [(True,'noc'),(False,'dzien')]:
            (folder/'images'/f"{scene['id']}-{name}.svg").write_text(picture(scene,result,dark))
        if result['problems']:(folder/'images'/f"{scene['id']}-diagnostyka.svg").write_text(picture(scene,result,True,True))
        if index%100==0:print(f'Audit {index}/{len(files)}',flush=True)
    glyph_path=folder/'geometry'/'arrow-glyphs.json'
    if glyph_path.exists():
        glyphs=json.loads(glyph_path.read_text())
        (folder/'arrows').mkdir(exist_ok=True)
        arrow_rows=[]
        labels={'left':'w lewo','right':'w prawo','through':'prosto','slight_left':'lekko w lewo','slight_right':'lekko w prawo',
            'sharp_left':'ostro w lewo','sharp_right':'ostro w prawo','reverse':'zawróć','merge_to_left':'włączenie w lewo','merge_to_right':'włączenie w prawo'}
        for index,glyph in enumerate(glyphs):
            issues=[]
            if any(not(.8<=x<=glyph['width']-.8 and .8<=y<=glyph['height']-.8) for line in glyph['paths'] for x,y in line):
                issues.append('Strzałka wykracza poza obszar grafiki')
            identifier=f'strzalka-{index:04d}'
            for dark,name in [(True,'noc'),(False,'dzien')]:
                palette=COLORS[dark]
                paths=''.join('<path d="M'+' L'.join(f'{x:.4f},{y:.4f}' for x,y in line)+'"/>' for line in glyph['paths'])
                svg=f"<svg xmlns='http://www.w3.org/2000/svg' width='384' height='384' viewBox='0 0 32 32'><rect width='32' height='32' fill='{palette['surface']}'/><g transform='translate(8,1)' fill='none' stroke='{palette['paint']}' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'>{paths}</g></svg>"
                (folder/'arrows'/f'{identifier}-{name}.svg').write_text(svg)
            arrow_rows.append(dict(id=identifier,title=' + '.join(labels[t] for t in glyph['turns']),family='strzalki',real=False,
                problems=issues,uncovered=0,checks=len(glyph['paths']),milliseconds=0,features=len(glyph['paths']),vertices=0,arrow=True))
        rows.extend(arrow_rows)
    if args.include:
        relative=args.include.relative_to(folder).as_posix()+'/'
        for row in json.loads((args.include/'audit.json').read_text()):
            if not row.get('arrow'): rows.append(dict(row,assetPrefix=relative))
    (folder/'audit.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
    families=collections.Counter(x['family'] for x in rows if x['problems'])
    print('Cases:',len(rows),'with problems:',sum(bool(x['problems']) for x in rows),'families:',families)
    data=json.dumps(rows,ensure_ascii=False).replace('</','<\\/')
    (folder/'index.html').write_text('''<!doctype html><html lang="pl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Atlas geometrii NaviAstra</title><style>body{margin:0;padding:28px;background:#121b22;color:#e5edf2;font:16px system-ui}header{max-width:1100px}h1{font-size:30px}p{color:#aabdc9;line-height:1.6}select,input,button{background:#24333f;color:#eff6fc;border:1px solid #465869;border-radius:8px;padding:10px;margin:5px}main{display:grid;grid-template-columns:repeat(auto-fill,minmax(310px,1fr));gap:18px}article{background:#1c2833;border:1px solid #354552;border-radius:12px;padding:12px}img{width:100%;aspect-ratio:1;object-fit:contain;border-radius:8px}h2{font-size:16px}.bad{color:#ff9a9f}.ok{color:#9ae1be}small{color:#aabdc9}nav{margin:20px 0}</style><header><h1>Atlas geometrii dróg NaviAstra</h1><p>Grafiki powstają z aktualnego kodu geometrii iOS. Układy kontrolne są syntetyczne; osobna grupa zawiera rzeczywiste dane z urządzenia. To rzut geometryczny do oceny połączeń, nie zrzut silnika MapLibre. Czerwone punkty w diagnostyce oznaczają niepokrytą oś drogi.</p></header><nav><select id="family"><option value="">Wszystkie rodziny</option></select><select id="status"><option value="">Wszystkie wyniki</option><option value="bad">Wymagają poprawy</option><option value="ok">Bez wykrytych luk</option></select><select id="theme"><option value="noc">Noc</option><option value="dzien">Dzień</option><option value="diagnostyka">Diagnostyka</option></select><input id="search" placeholder="Szukaj wariantu"><button id="prev">Poprzednie</button><button id="next">Następne</button><span id="count"></span></nav><main></main><script>const rows='''+data+''';const $=s=>document.querySelector(s);let page=0;for(const f of [...new Set(rows.map(x=>x.family))].sort())$('#family').add(new Option(f,f));function draw(){const f=$('#family').value,s=$('#status').value,q=$('#search').value.toLowerCase(),t=$('#theme').value;const filtered=rows.filter(x=>(!f||x.family===f)&&(!s||(s==='bad')===!!x.problems.length)&&(!q||(x.title+' '+x.id).toLowerCase().includes(q)));page=Math.max(0,Math.min(page,Math.ceil(filtered.length/48)-1));$('#count').textContent=`${filtered.length} układów · strona ${page+1}/${Math.max(1,Math.ceil(filtered.length/48))}`;const main=$('main');main.replaceChildren();for(const row of filtered.slice(page*48,page*48+48)){const a=document.createElement('article');const h=document.createElement('h2');h.textContent=row.title;a.append(h);const image=document.createElement('img');image.loading='lazy';image.src=`${row.assetPrefix||''}${row.arrow?'arrows':'images'}/${row.id}-${t==='diagnostyka'&&(row.arrow||!row.problems.length)?'noc':t}.svg`;a.append(image);const note=document.createElement('p');note.className=row.problems.length?'bad':'ok';note.textContent=row.problems.join(' · ')||'Bez wykrytych luk';a.append(note);const small=document.createElement('small');small.textContent=`${row.id} · ${row.checks} próbek · ${Math.round(row.milliseconds)} ms`;a.append(small);main.append(a)}}for(const id of ['family','status','theme','search'])$('#'+id).oninput=()=>{page=0;draw()};$('#prev').onclick=()=>{page--;draw()};$('#next').onclick=()=>{page++;draw()};draw();</script></html>''')

if __name__=='__main__':main()
