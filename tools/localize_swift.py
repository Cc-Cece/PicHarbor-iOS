"""List/localize Chinese Swift literals, preserving interpolation expressions.

Run once with --apply after reviewing the translation table. --check audits
unwrapped literals; never alters user content or persisted enum identifiers.
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

def quoted(text, start):
    i = start + 1
    while i < len(text):
        if text.startswith('\\(', i):
            i = expression(text, i + 2)[1]
        elif text[i] == '\\':
            i += 2
        elif text[i] == '"':
            return i + 1
        else:
            i += 1
    raise ValueError('Unclosed Swift string')

def expression(text, start):
    depth, i = 1, start
    while i < len(text):
        if text[i] == '"':
            i = quoted(text, i)
            continue
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                return text[start:i], i + 1
        i += 1
    raise ValueError('Unclosed interpolation')

def template(literal):
    result, args, i = '', [], 1
    while i < len(literal) - 1:
        if literal.startswith('\\(', i):
            arg, i = expression(literal, i + 2)
            result += '{' + str(len(args)) + '}'
            args.append(arg)
        elif literal[i] == '\\':
            result += literal[i:i+2]; i += 2
        else:
            result += literal[i]; i += 1
    return result, args

def transform(text, collect):
    result, i = '', 0
    while i < len(text):
        if text.startswith('//', i):
            end = text.find('\n', i)
            if end < 0: end = len(text)
            result += text[i:end]; i = end
        elif text.startswith('/*', i):
            end = text.index('*/', i) + 2
            result += text[i:end]; i = end
        elif text[i] == '"':
            end = quoted(text, i); literal = text[i:end]
            key, args = template(literal)
            # Chinese literals are already translated when inside L10n.text.
            if re.search('[\u3400-\u9fff]', key) and not text[max(0, i-10):i].endswith('L10n.text('):
                collect.add(key)
                values = ', '.join('String(describing: ' + transform(a, collect) + ')' for a in args)
                result += 'L10n.text("' + key + '"' + (', [' + values + ']' if values else '') + ')'
            else:
                result += literal
            i = end
        else:
            result += text[i]; i += 1
    return result

if __name__ == '__main__':
    keys = set()
    for path in (ROOT / 'Sources').rglob('*.swift'):
        if path.name == 'Localization.swift': continue
        text = path.read_text(encoding='utf-8')
        updated = transform(text, keys)
        if '--apply' in sys.argv: path.write_text(updated, encoding='utf-8')
    if '--check' in sys.argv:
        print(json.dumps({'unlocalized_literals': sorted(keys)}, ensure_ascii=False))
        sys.exit(bool(keys))
    output = ROOT / 'build/localization-keys.json'
    output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(sorted(keys), ensure_ascii=False, indent=2), encoding='utf-8')
    print(len(keys), 'keys:', output)
