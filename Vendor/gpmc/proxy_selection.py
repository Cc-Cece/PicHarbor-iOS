"""Platform-independent node choice. No credentials, connections or persistence."""
def select_proxy(value):
    if not isinstance(value, dict):
        return {"ok": False, "error": "INVALID_ARGUMENT"}
    policy, nodes = value.get('policy', {}), value.get('nodes', [])
    if not isinstance(policy, dict) or not isinstance(nodes, list):
        return {"ok": False, "error": "INVALID_ARGUMENT"}
    if policy.get('selection', 'automatic') not in ('automatic', 'manual'):
        return {"ok": False, "error": "INVALID_ARGUMENT"}
    available = [n for n in nodes if isinstance(n, dict) and isinstance(n.get('name'), str)
                 and n.get('healthy', True) is True and not n.get('cooling', False)]
    if policy.get('selection') == 'manual':
        ordered = [policy.get('primary')] + list(policy.get('backups', []))
        for name in ordered:
            if any(n['name'] == name for n in available):
                return {'node': name, 'direct': False, 'waiting': False}
    elif available:
        current = value.get('current')
        if any(n['name'] == current for n in available):
            return {'node': current, 'direct': False, 'waiting': False}
        best = min(available, key=lambda n: (n.get('latency') if isinstance(n.get('latency'), (int, float)) and n['latency'] >= 0 else 2**31, n['name']))
        return {'node': best['name'], 'direct': False, 'waiting': False}
    direct = policy.get('exhaustion', 'wait') == 'direct'
    return {'node': '', 'direct': direct, 'waiting': not direct}
