"""Choose only versions that a platform explicitly exposes for an asset."""


def select_versions(value):
    policy = value.get('policy', 'both')
    available = value.get('available')
    edited = value.get('has_edits')
    if policy not in ('both', 'original', 'current') or not isinstance(available, list) or any(
            version not in ('original', 'current') for version in available) or (
            edited is not None and type(edited) is not bool):
        return {'ok': False, 'error': 'INVALID_ARGUMENT'}
    available = set(available)
    if not available:
        return {'ok': False, 'error': 'VERSION_RESOURCE_MISSING'}
    if policy == 'original':
        if 'original' not in available:
            return {'ok': False, 'error': 'ORIGINAL_VERSION_UNAVAILABLE'}
        selected = ['original']
    elif policy == 'current':
        if 'current' in available:
            selected = ['current']
        elif edited is False and 'original' in available:
            selected = ['original']
        else:
            return {'ok': False, 'error': 'CURRENT_VERSION_UNAVAILABLE'}
    else:
        if edited is True and available != {'original', 'current'}:
            return {'ok': False, 'error': 'VERSION_RESOURCE_MISSING'}
        selected = [version for version in ('original', 'current') if version in available]
    return {'versions': selected, 'original_available': 'original' in available,
            'current_available': 'current' in available}
