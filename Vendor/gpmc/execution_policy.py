"""Cross-platform task protection values and size-aware file budget."""

DEFAULTS = dict(retries=3, query_seconds=60, commit_seconds=90, idle_seconds=120, file_minutes=120, cloud_minutes=60)
RANGES = dict(retries=(0, 10), query_seconds=(15, 300), commit_seconds=(15, 600),
              idle_seconds=(30, 1800), file_minutes=(10, 1440), cloud_minutes=(10, 240))


def resolve_execution(value):
    overrides = value.get('overrides') or DEFAULTS
    if not isinstance(overrides, dict) or any(type(overrides.get(key)) is not int or not low <= overrides[key] <= high
                                              for key, (low, high) in RANGES.items()):
        return {'ok': False, 'error': 'INVALID_EXECUTION_POLICY'}
    size = value.get('size', 0)
    if type(size) is not int or size < 0:
        return {'ok': False, 'error': 'INVALID_ARGUMENT'}
    policy = {key: overrides[key] for key in RANGES}
    return {'policy': policy, 'file_seconds': min(policy['file_minutes'] * 60, max(600, 300 + size / (64 * 1024)))}
