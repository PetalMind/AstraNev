#!/usr/bin/env python3
"""Render the actual iOS road geometry into an auditable case atlas; no routing mocks."""
import argparse
import hashlib
import itertools
import json
import math
import pathlib
import subprocess
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
METERS = 6_371_008.8 * math.pi / 180
LAT, LON = 52.0, 19.0
QUERY = dict(south=LAT-.002, north=LAT+.002, west=LON-.003, east=LON+.003)


def road(points, lanes=2, direction='two', road_class='primary', widths=True, extra=None):
    tags = {'highway': road_class}
    if lanes is not None:
        tags['lanes'] = str(lanes)
        if widths: tags['width'] = str(lanes * 3.2)
        if direction == 'two':
            tags['lanes:forward'] = str((lanes+1)//2)
            tags['lanes:backward'] = str(lanes//2)
    if direction in ('yes', '-1'): tags['oneway'] = direction
    if extra: tags.update(extra)
    return {'id': 0, 'points': [dict(latitude=LAT+y/METERS, longitude=LON+x/(METERS*math.cos(math.radians(LAT)))) for x,y in points], 'tags': tags}


def polar(angle, length=80):
    return (math.cos(math.radians(angle))*length, math.sin(math.radians(angle))*length)


def cases():
    result=[]
    def add(family, title, roads, expected=None):
        for i,r in enumerate(roads): r['id']=i+1
        result.append(dict(id=f'{family}-'+hashlib.sha256(json.dumps(roads,sort_keys=True).encode()).hexdigest()[:12], family=family, title=title, roads=roads,
                           query=QUERY, expectedJunctions=expected, real=False))
    for n,m in itertools.product(range(1,13), repeat=2):
        for direction in ('yes','-1'):
            add('zmiana-pasow',f'{n} → {m} pasów · kierunek {direction}',
                [road([(-90,0),(0,0)],n,direction),road([(0,0),(90,0)],m,direction)],1)
    for angle in [5,10,15,20,30,45,60,90,120,150,170,175]:
        for n,m in itertools.product(range(1,13),repeat=2):
            add('zakret',f'Łuk {angle}° · {n}/{m} pasów',
                [road([(-80,0),(0,0)],n,'yes'),road([(0,0),polar(angle)],m,'yes')],1)
    for angle in [10,20,30,45,60,75,90,105,120,150,170]:
        for n,m in itertools.product(range(1,13), repeat=2):
            add('skrzyzowanie-t',f'Wlot {angle}° · {n}/{m} pasów',
                [road([(-90,0),(0,0),(90,0)],n,'two'),road([(0,0),polar(angle)],m,'two')],1)
    for angle in [5,10,15,20,30,45,60,90,120]:
        for n,m,k in itertools.product(range(1,13),repeat=3):
            for side in [-1,1]:
                add('rozwidlenie',f'Rozdział {n} → {m}+{k} · {angle*side}°',
                    [road([(-90,0),(0,0)],n,'yes'),road([(0,0),(90,0)],m,'yes'),road([(0,0),polar(side*angle)],k,'yes')],1)
    for angle in [20,45,60,90,120,150,160]:
        for n,m in itertools.product(range(1,13),repeat=2):
            p=polar(angle)
            add('skrzyzowanie-x',f'Przecięcie {angle}° · {n}/{m} pasów',
                [road([(-90,0),(0,0),(90,0)],n,'two'),road([(-p[0],-p[1]),(0,0),p],m,'two')],1)
    for radius in [4,6,10,15,25,40]:
        for lanes in [1,2,3]:
            for entrances in [0,1,2,3,4,6,8]:
                ring=[polar(i*5,radius) for i in range(73)]
                roads=[road(ring,lanes,'yes',extra={'junction':'roundabout'})]
                for i in range(entrances):
                    angle=i*360/entrances
                    roads.append(road([polar(angle,radius),polar(angle,radius+70)],2,'two'))
                add('rondo',f'Rondo r={radius} m · {lanes} pasów · {entrances} wlotów',roads)
    for length in [0.4,1,2,4,8,12,20]:
        for n,m in itertools.product([1,2,3,4],repeat=2):
            add('krotkie-laczniki',f'Łącznik {length} m · {n}/{m} pasów',
                [road([(-80,0),(0,0)],n),road([(0,0),(length,0)],n),road([(length,0),(80,0)],n),
                 road([(0,0),(0,75)],m),road([(length,0),(length,-75)],m)])
    for angle in [15,30,45,60,90,120,150]:
        for n in [1,2,3,4]:
            for known in [False,True]:
                extra={} if known else {'lane_markings':'no'}
                add('braki-danych',f'Dane częściowe · {angle}° · {n} pasów · oznaczenia {known}',
                    [road([(-80,0),(0,0),(80,0)],n,'two',widths=False),road([(0,0),polar(angle)],None,extra=extra)],1)
    for layer in [-1,0,1,2]:
        for bridge in [False,True]:
            add('poziomy',f'Przecięcie · layer={layer} · most={bridge}',
                [road([(-80,0),(0,0),(80,0)],2,extra={'layer':str(layer),'bridge':'yes' if bridge else 'no'}),road([(0,-80),(0,0),(0,80)],2)])
    for gap in [.05,.2,.6,1.0,1.2,1.3,2,4]:
        add('dopasowanie',f'Luka końców {gap} m',[road([(-80,0),(0,0)]),road([(gap,0),(80,0)])],1 if gap<=1.25 else 0)
    for n in [1,2,3,4,6,12]:
        for gap in [0.5,1,2,4,8]:
            add('rownolegle',f'Równoległe jezdnie · odstęp {gap} m · {n} pasów',
                [road([(-80,0),(0,0),(80,0)],n,'yes'),road([(-80,gap),(0,gap),(80,gap)],n,'-1')],0)
    for placement in ['middle_of:1','left_of:1','right_of:1','middle_of:2']:
        for n in [2,3,4]:
            add('przesuniecie-osi',f'Oś {placement} · {n} pasów',
                [road([(-80,0),(0,0)],n,'yes',extra={'placement':placement}),road([(0,0),(80,0)],n,'yes')],1)
    for shape,points in [('hairpin',[(-80,0),(0,0),(-75,5)]),('zygzag',[(-80,0),(-3,0),(0,3),(3,0),(80,0)]),('luk',[(-80,0),(-30,0),(-10,5),(0,15),(0,80)])]:
        for n in [1,2,3,4,6,12]:
            add('krzywizna',f'{shape} · {n} pasów',[road(points,n,'yes')],0)
    return result


def contracts():
    result=[]
    def add(family,title,roads,expected=None,normalized=None,markings=None):
        for i,r in enumerate(roads): r['id']=i+1
        identifier=family+'-'+hashlib.sha256(json.dumps(roads,sort_keys=True).encode()).hexdigest()[:12]
        result.append(dict(id=identifier,family=family,title=title,roads=roads,query=QUERY,real=False,
                           expectedJunctions=expected,expectedNormalized=normalized,expectedMarkingsMinimum=markings))
    classes=['motorway','trunk','primary','secondary','tertiary','residential','unclassified','living_street','service',
             'motorway_link','trunk_link','primary_link','secondary_link','tertiary_link']
    profiles=['pelny','liczba-pasow','szerokosc','klasa','błędne-pasy','pobocze','zanik-pasa','zanik-calej-jezdni']
    for cls,profile,direction,side,marked in itertools.product(classes,profiles,['two','yes','-1','reversible','unknown'],['right','left'],[True,False]):
        kwargs=dict(direction=direction,road_class=cls)
        n=1 if profile=='zanik-calej-jezdni' else 2
        roads=[road([(-80,0),(0,0)],n,**kwargs),road([(0,0),(80,0)],n,**kwargs)]
        for r in roads:
            tags=r['tags'];tags['driving_side']=side;tags['lane_markings']='yes' if marked else 'no'
            if direction in ['reversible','unknown']:tags['oneway']=direction
            if direction=='two':tags['oneway']='no'
            if profile=='liczba-pasow':tags.pop('width',None)
            if profile in ['szerokosc','klasa']:
                for key in ['lanes','lanes:forward','lanes:backward']:tags.pop(key,None)
                if profile=='klasa':tags.pop('width',None)
            if profile=='błędne-pasy':tags['lanes']='-1'
            if profile=='pobocze':tags['shoulder']='yes'
            if profile in ['zanik-pasa','zanik-calej-jezdni']:
                tags.pop('width',None)
                tags['width:lanes:start']='3.2|3.2' if n==2 else '3.2'
                tags['width:lanes:end']='3.2|0' if n==2 else '0'
        add('kontrakt-zrodla',f'{cls} · {profile} · ruch {direction} · strona {side} · oznaczenia {marked}',roads,
            normalized=0 if profile=='błędne-pasy' else 2)
    for a,b,direction in itertools.product(classes,classes,['yes','-1']):
        add('zmiana-klasy',f'Zmiana klasy {a} → {b} · ruch {direction}',
            [road([(-80,0),(0,0)],2,direction,a),road([(0,0),(80,0)],2,direction,b)],1,2,1)
    for directions in itertools.product(['two','yes','-1'],repeat=3):
        for angle in [15,45,90,150]:
            for counts in [(1,1,1),(2,2,1),(4,3,2),(12,12,12)]:
                add('kierunki-ruchu',f'Kierunki {directions} · pasy {counts} · {angle}°',
                    [road([(-80,0),(0,0)],counts[0],directions[0]),road([(0,0),(80,0)],counts[1],directions[1]),
                     road([(0,0),polar(angle)],counts[2],directions[2])],1,3)
    for a,b in itertools.product(range(-3,6),repeat=2):
        for crossing in [False,True]:
            if crossing:
                roads=[road([(-80,0),(0,0),(80,0)],2,'yes',extra={'layer':str(a),'bridge':'yes'}),
                       road([(0,-80),(0,0),(0,80)],2,'yes',extra={'layer':str(b)})]
                roads[0]['nodeIDs']=[11,100,12];roads[1]['nodeIDs']=[21,100,22]
                expected=1 if a==b else 0
                if a==b:roads[0]['tags']['bridge']='no'
            else:
                roads=[road([(-80,0),(0,0)],2,'yes',extra={'layer':str(a),'bridge':'yes'}),
                       road([(0,0),(80,0)],2,'yes',extra={'layer':str(b)})]
                roads[0]['nodeIDs']=[11,100];roads[1]['nodeIDs']=[100,22];expected=1
            add('granice-poziomow',f'Poziomy {a} → {b} · przecięcie {crossing}',roads,expected,2)
    for n in range(1,13):
        for lane in range(1,n+1):
            for placement,direction in itertools.product(['middle_of','left_of','right_of'],['yes','-1']):
                value=f'{placement}:{lane}'
                add('pelne-przesuniecia',f'Oś {value} · {n} pasów · ruch {direction}',
                    [road([(-80,0),(0,0)],n,direction,extra={'placement':value}),road([(0,0),(80,0)],n,direction)],1,2)
    for size in [10_001,20_000,80_000]:
        add('dlugie-osie',f'Oś {size} m z częścią w widoku',[road([(-size/2,0),(size/2,0)],2)],0,1)
    return result


def prepare_driver(destination, source):
    hashes={}
    for name in ['DetailedRoadGeometry.swift','DetailedRoadTopology.swift','DetailedRoadSurfaceGeometry.swift','DetailedRoadArrowGeometry.swift','NormalizedDetailedRoad.swift']:
        if not (source/name).exists(): continue
        raw=(source/name).read_text(); hashes[name]=hashlib.sha256(raw.encode()).hexdigest()
        assert raw.startswith('#if os(iOS)\n') and raw.rstrip().endswith('#endif')
        # Only the platform envelope is omitted. The iOS algorithms are copied verbatim.
        (destination/name).write_text(raw.removeprefix('#if os(iOS)\n').rstrip().removesuffix('#endif'))
    provider=(source/'DetailedRoadProvider.swift').read_text()
    models=provider.split('actor OverpassDetailedRoadProvider:')[0].removeprefix('#if os(iOS)\n').replace('import OSLog\n','')
    (destination/'Models.swift').write_text(models)
    hashes['DetailedRoadProvider.swift']=hashlib.sha256(provider.encode()).hexdigest()
    (destination/'main.swift').write_text((REPO/'scripts/road-atlas/GeometryDriver.swift').read_text())
    flags=[]
    if (source/'DetailedRoadSurfaceGeometry.swift').exists(): flags+=['-D','ROAD_ATLAS_SURFACES']
    if (source/'DetailedRoadArrowGeometry.swift').exists(): flags+=['-D','ROAD_ATLAS_GLYPHS']
    subprocess.run(['xcrun','swiftc','-O',*flags,*map(str,destination.glob('*.swift')),'-o',str(destination/'geometry'),'-module-cache-path',str(destination/'module-cache')],check=True)
    return hashes


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',required=True,type=pathlib.Path)
    parser.add_argument('--real-cache',type=pathlib.Path)
    parser.add_argument('--limit',type=int)
    parser.add_argument('--scope',choices=['geometry','contracts','all'],default='all')
    parser.add_argument('--source-dir',type=pathlib.Path,default=REPO/'NaviAstra/Maps/iOS')
    args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    scenes=(cases() if args.scope in ['geometry','all'] else [])+(contracts() if args.scope in ['contracts','all'] else [])
    if args.limit: scenes=scenes[:args.limit]
    if args.real_cache:
        for i,entry in enumerate(json.loads(args.real_cache.read_text())):
            scenes.append(dict(id=f'real-{i:02d}',title=f'Dane z urządzenia · obszar {i+1}',family='dane-rzeczywiste',roads=entry['roads'],query=entry['query'],real=True))
    with tempfile.TemporaryDirectory(prefix='naviastra-road-atlas-') as folder:
        temporary=pathlib.Path(folder)
        hashes=prepare_driver(temporary,args.source_dir)
        input_path=temporary/'scenes.json'; input_path.write_text(json.dumps(scenes))
        snapshot=args.output/'sources'; snapshot.mkdir(exist_ok=True)
        for name in hashes:
            (snapshot/name).write_bytes((args.source_dir/name).read_bytes())
        for name in ['run.py','GeometryDriver.swift','audit.py']:
            (snapshot/name).write_bytes((REPO/'scripts/road-atlas'/name).read_bytes())
        import gzip
        with gzip.open(args.output/'scenes.json.gz','wb') as archive: archive.write(input_path.read_bytes())
        (args.output/'provenance.json').write_text(json.dumps(dict(sources=hashes,cases=len(scenes),
            inputsSHA256=hashlib.sha256(input_path.read_bytes()).hexdigest()),indent=2))
        subprocess.run([str(temporary/'geometry'),str(input_path),str(args.output/'geometry')],check=True)
    print(f'Atlas geometry: {args.output}')

if __name__=='__main__': main()
