#!/usr/bin/env python3
"""Verify the published metrics offline. No server, database, Docker or network work."""
import argparse
import hashlib
import json
from pathlib import Path
from statistics import median

HERE = Path(__file__).resolve().parent
NAMES = {'samples.json', 'summary.json', 'hardware.json', 'image-proofs.json',
         'write-audit.json', 'runtime-source.json', 'provenance.json',
         'source-count.json', 'README.md', 'verify.py', 'reproduce.rb'} | {
             f'raw/http-{n}.json' for n in range(1, 91)}


def read(name):
    return json.loads((HERE / name).read_text())


def digest(path):
    assert path.is_file() and not path.is_symlink(), path
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if not __debug__:
        raise RuntimeError('Run without Python -O; assertions perform verification.')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, help='Optionally check all 330 runtime files in a measured-source checkout.')
    args = parser.parse_args()
    hashes = read('SHA256SUMS.json')
    observed = set()
    for path in HERE.rglob('*'):
        assert not path.is_symlink(), path
        if path.is_file() and path != HERE / 'SHA256SUMS.json':
            observed.add(str(path.relative_to(HERE)))
    assert set(hashes) == observed == NAMES
    for name, expected in hashes.items():
        assert digest(HERE / name) == expected, name
    index, summary, provenance = read('samples.json'), read('summary.json'), read('provenance.json')
    assert index['round_order'] == provenance['round_order']
    assert index['routes'] == provenance['route_order']
    assert len(index['samples']) == summary['raw_samples'] == 90
    assert summary['timed_samples'] == 45 and summary['application_rounds'] == 9
    apps, routes = summary['all_measured_apps'], index['routes']
    assert apps == ['c', 'julia-4-0', 'julia-2-2']
    assert routes == ['room_show', 'messages_page', 'sidebar', 'search', 'post_message']
    assert index['round_order'] == [apps, apps[1:] + apps[:1], apps[2:] + apps[:2]]
    values = {route: {app: [] for app in apps} for route in routes}
    post_counts = {(app, r): 0 for app in apps for r in range(1, 4)}
    all_responses = timed_responses = 0
    route_paths = {}
    for number, item in enumerate(index['samples'], 1):
        assert item['file'] == f'raw/http-{number}.json'
        assert digest(HERE / item['file']) == item['sha256']
        offset = number - 1
        round_no = offset // 30 + 1
        app = index['round_order'][round_no - 1][offset % 30 // 10]
        route = routes[offset % 10 // 2]
        phase = 'timed' if number % 2 == 0 else 'warmup'
        assert (item['round'], item['app'], item['route'], item['phase']) == (round_no, app, route, phase)
        sample = read(item['file'])
        assert sample['errors'] == sample['invalid_responses'] == 0
        assert sample['invalid_reasons'] == {} and sample['gzip'] is True
        assert sample['validation'] == 'route-contract-v1'
        assert sample['ok'] == sample['latency']['n'] > 0
        assert sample['statuses'] == {'200': sample['ok']}
        assert sample['conc'] == (16 if phase == 'timed' else 4)
        assert sample['secs'] >= (15 if phase == 'timed' else 10)
        route_paths.setdefault(route, sample['path'])
        assert sample['path'] == route_paths[route]
        assert sample['path'].startswith('POST ') == (route == 'post_message')
        all_responses += sample['ok']
        if phase == 'timed':
            timed_responses += sample['ok']
            values[route][app].append(sample)
        if route == 'post_message':
            post_counts[app, round_no] += sample['ok']
    assert all_responses == summary['validated_responses'] == 85873050
    assert timed_responses == summary['timed_responses'] == 58969779
    for route, by_app in values.items():
        for app, samples in by_app.items():
            expected = {
                'rps_samples': [s['rps'] for s in samples],
                'median_rps': median(s['rps'] for s in samples),
                'p99_ms_samples': [s['latency']['p99_ms'] for s in samples],
                'median_p99_ms': median(s['latency']['p99_ms'] for s in samples),
                'max_container_lifetime_peak_mib': max(s['server_resources']['memory_lifetime_peak_bytes'] for s in samples) / 2**20,
            }
            assert summary['routes'][route][app] == expected
    audit = read('write-audit.json')
    assert audit['historical_audit_verified'] and audit['receipt_files'] == len(audit['receipt_hashes']) == 18
    assert sum(post_counts.values()) == summary['audited_acknowledged_writes'] == audit['total_acknowledged'] == 1194890
    assert sum(row['lines'] for row in audit['receipt_hashes'].values()) == audit['total_acknowledged']
    for app, profile in audit['profiles'].items():
        assert profile['receipt_files'] == 6
        assert sum(post_counts[app, r] for r in range(1, 4)) == profile['acknowledged']
        for row in profile['rounds']:
            assert row['verified'] and row['integrity_check'] == 'ok'
            assert row['acknowledged'] == post_counts[app, row['round']] == row['exact_body_and_search_matches'] == row['total_message_growth']
            assert row['unexpected_or_missing_new_messages'] == row['missing_fts_entries'] == 0
    source = read('runtime-source.json')
    combined = hashlib.sha256()
    assert source['file_count'] == len(source['files']) == 330
    for name, file_hash in sorted(source['files'].items()):
        combined.update(name.encode() + b'\0' + file_hash.encode() + b'\0')
        if args.source:
            assert digest(args.source / name) == file_hash, name
    assert combined.hexdigest() == source['runtime_source_sha256'] == provenance['original_source_revisions']['julia-2-2']['runtime_source_sha256']
    assert source['standalone_commit'] == provenance['standalone_measured_commit']
    proofs = read('image-proofs.json')
    for proof in proofs.values():
        assert proof['verified']
    assert proofs['image-source.json']['image_id'] == provenance['images']['julia-2-2']
    assert proofs['final-source-match.json']['runtime_source_sha256'] == source['runtime_source_sha256']
    for name, expected in proofs['image-source.json']['runtime_source_sha256'].items():
        assert source['files'][name] == expected
    assert proofs['c-image-proof.json']['image_id'] == provenance['images']['c']
    assert proofs['c-image-proof.json']['source_commit'] == provenance['original_source_revisions']['c']['head']
    print(json.dumps({'verified': True, 'hashed_files': len(hashes), 'raw_samples': 90,
        'timed_samples': 45, 'validated_responses': all_responses, 'timed_responses': timed_responses,
        'historically_audited_writes': audit['total_acknowledged'], 'runtime_files_checked': 330 if args.source else 0,
        'scope': 'Hashes, numerical consistency and source/image links; does not repeat private database audit or measurements.'}, indent=2))


if __name__ == '__main__':
    main()
