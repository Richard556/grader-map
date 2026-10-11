"""
Adds two properties to every road in sverdrup_roads.geojson:

  MAINT   "township"    - graded by the township, counted in mileage
          "town"        - City of Baltic street, not township work (faint, not tappable)
          "subdivision" - waiting on a township decision; counted for now
                          (switch off with COUNT_SUBDIVISIONS in index.html)
  LEN_MI  segment length in miles

To change one road later, edit its MAINT value here and rerun:
    python3 tools/tag_roads.py
"""
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
GEOJSON = os.path.join(HERE, '..', 'sverdrup_roads.geojson')

# City of Baltic street grid
TOWN_STREETS = {
    '1ST ST', '2ND ST', '3RD ST', '4TH ST', '5TH ST', 'N 5TH ST',
    'LOVELY AVE', 'MIKES TRL', 'NORTH PL', 'ASH AVE', 'OAK AVE', 'ELM AVE',
    'DOUGLAS BLVD', 'DOUGLAS DR', 'JANS CIR', 'RICHARDS CIR', 'BONNIES CIR',
    'CAITLIN AVE', 'NIDAROS AVE', 'ST OLAF AVE', 'BULLDOG AVE', 'VIKING AVE',
    'MOREFIELD AVE', 'JOHNSON AVE', 'KRINGEN AVE', 'RIVERPARK RD',
    # East side of Baltic (newer neighborhoods inside town)
    'AANA AVE', 'KYLE AVE', 'SUNI AVE', 'N 6TH ST', 'S 6TH ST', '7TH ST',
    'RONALD CT', 'NICHOLE CV', 'KAROL CIR', 'VALLEY VIEW AVE', 'MEADOW ST',
    'PRAIRIE AVE', 'ELLA AVE', 'IVER AVE', 'PEYTON ST', 'LANEY LN',
    'ELIZABETH AVE', 'KATHRYN DR',
}

# Pending township decision
SUBDIVISION_STREETS = {
    # Near 475th Ave & 255th St
    'WASHINGTON ST', 'LINCOLN ST', 'ROCK RIDGE AVE', 'STONEWAY AVE', 'HELEN TRL',
    # Spurs off the section roads
    'SCANDIA DR', 'RIVERBEND PL', 'VISTA RIDGE PL', 'MEADOWLAND ST',
}

# Per-segment overrides by OBJECTID, e.g. {12345: 'town'}
OVERRIDES = {
    12456: 'town',  # 250th St between 6th and 7th St, inside Baltic
}


def miles(a, b):
    r = 3958.8
    la1, lo1, la2, lo2 = map(math.radians, (a[1], a[0], b[1], b[0]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def line_miles(geom):
    lines = geom['coordinates'] if geom['type'] == 'MultiLineString' else [geom['coordinates']]
    return sum(miles(l[i], l[i + 1]) for l in lines for i in range(len(l) - 1))


def main():
    with open(GEOJSON) as f:
        data = json.load(f)

    totals = {}
    for feat in data['features']:
        p = feat['properties']
        name = p.get('STREETNAME', '')
        maint = OVERRIDES.get(p.get('OBJECTID'))
        if not maint:
            maint = 'town' if name in TOWN_STREETS else 'subdivision' if name in SUBDIVISION_STREETS else 'township'
        p['MAINT'] = maint
        p['LEN_MI'] = round(line_miles(feat['geometry']), 4)
        totals[maint] = totals.get(maint, 0) + p['LEN_MI']

    # Same layout as the original export: one feature per line
    head = {k: v for k, v in data.items() if k != 'features'}
    out = ['{']
    for k, v in head.items():
        out.append(f'"{k}": {json.dumps(v)},')
    out.append('"features": [')
    feats = [json.dumps(f, separators=(',', ':')) for f in data['features']]
    out.append(',\n'.join(feats))
    out.append(']')
    out.append('}')
    with open(GEOJSON, 'w') as f:
        f.write('\n'.join(out) + '\n')

    for k in sorted(totals):
        print(f'{k:12s} {totals[k]:7.2f} mi')


if __name__ == '__main__':
    main()
