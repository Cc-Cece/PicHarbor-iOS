"""Shared admission limits; native clients supply device pressure measurements."""

RANGES = {'preparation': (1, 3), 'lookup': (1, 4), 'upload': (1, 12),
          'commit': (1, 4), 'confirmation': (1, 4), 'buffer_mb': (128, 8192)}


def resolve_pipeline(value):
    mode, device = value.get('mode', 'automatic'), value.get('device', {})
    if mode not in ('automatic', 'custom') or not isinstance(device, dict):
        return {'ok': False, 'error': 'INVALID_ARGUMENT'}
    memory = device.get('memory_gb', 4)
    if type(memory) is not int or memory < 1:
        return {'ok': False, 'error': 'INVALID_ARGUMENT'}
    if mode == 'custom':
        limits = value.get('limits')
        if not isinstance(limits, dict) or any(type(limits.get(key)) is not int or not low <= limits[key] <= high
                                               for key, (low, high) in RANGES.items()):
            return {'ok': False, 'error': 'INVALID_PIPELINE_LIMITS'}
        limits = {key: limits[key] for key in RANGES}
    elif device.get('profile') == 'performance' and memory >= 8:
        limits = dict(preparation=2, lookup=3, upload=6, commit=2, confirmation=2, buffer_mb=768)
    elif device.get('profile') == 'balanced' and memory >= 6:
        limits = dict(preparation=1, lookup=2, upload=4, commit=2, confirmation=1, buffer_mb=512)
    else:
        limits = dict(preparation=1, lookup=2, upload=3 if memory >= 4 else 2, commit=1, confirmation=1, buffer_mb=256)
    available, thermal = device.get('available_mb', 512), device.get('thermal', 0)
    processors, free = device.get('processors', 4), device.get('free_disk_mb', 4096)
    if any(type(number) is not int or number < 0 for number in (available, thermal, processors, free)):
        return {'ok': False, 'error': 'INVALID_ARGUMENT'}
    if memory < 6:
        limits['preparation'] = min(limits['preparation'], 1)
        limits['upload'] = min(limits['upload'], 4)
    if device.get('low_power') is True or thermal >= 2 or processors <= 2 or available < 256:
        for key in ('preparation', 'lookup', 'commit', 'confirmation'):
            limits[key] = min(limits[key], 1)
        limits['upload'] = min(limits['upload'], 2)
    if device.get('memory_warning') is True or thermal >= 3 or available < 128 or free < 128:
        limits['preparation'] = 0
        limits['upload'] = min(limits['upload'], 1)
    limits['buffer_mb'] = min(limits['buffer_mb'], max(64, free - 128))
    return {'limits': limits}
