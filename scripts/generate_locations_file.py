import numpy as np
import time
from geopy.geocoders import Nominatim as geocoder
from augur.utils import read_lat_longs, read_metadata

geoloc = geocoder(user_agent='augur/flu')
last_request = 0

def get_geo_info(location_tuple):
    # Nominatim usage policy limits requests to 1/s
    global last_request
    if time.time()-last_request<1.1:
        time.sleep(1.1 - time.time()+last_request)
    last_request = time.time()
    print('requesting geo info for:', location_tuple)
    return geoloc.geocode(", ".join(location_tuple))


def determine_coordinates(metadata, field):
    existing_coordinates = read_lat_longs()
    new_coordinates = {}
    failed_queries = {}
    for m in metadata.values():
        if (field, m[field].lower()) in existing_coordinates:
            continue
        elif (field, m[field].lower()) in new_coordinates:
            continue
        elif (field, m[field].lower()) in failed_queries:
            continue
        else:
            if field=='country':
                loc_tuple = (m[field],)
            elif field=='division':
                loc_tuple = (m['country'], m[field])
            elif field=='location':
                loc_tuple = (m['country'], m['division'], m[field])
            else:
                print(f'field {field} not supported')
                continue
            loc = get_geo_info(loc_tuple)
            if loc:
                new_coordinates[(field, m[field].lower())] = {'latitude':loc.latitude,
                                                    'longitude':loc.longitude}
            else:
                print(loc_tuple, "not found")
                failed_queries[(field, m[field].lower())] = None
    return new_coordinates

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(
        description="Use json summarizing titers to plot average titers by clades",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )

    parser.add_argument('--metadata', type=str, help="metadata file")
    parser.add_argument('--field', type=str, help="location field to use")
    parser.add_argument('--filter', type=str, nargs='+', help="subset of entries by higher level geographic location")
    parser.add_argument('--output', type=str, help="output file")
    args = parser.parse_args()

    metadata, columns = read_metadata(args.metadata)
    subset = {}
    if args.filter:
        assert len(args.filter)%2==0
        for sname, s in metadata.items():
            if all([s[args.filter[2*fi]].lower()==args.filter[2*fi+1].lower() for fi in range(len(args.filter)//2)]):
                subset[sname]=s
    else:
        subset = metadata

    locations = determine_coordinates(subset, args.field)

    with open(args.output, 'wt') as fh:
        # TODO add header in future
        for (f,v),loc in locations.items():
            fh.write(f"{f}\t{v}\t{loc['latitude']}\t{loc['longitude']}\n")
