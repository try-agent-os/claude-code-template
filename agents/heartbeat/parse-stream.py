#!/usr/bin/env python3
"""Parse claude stream-json into readable log lines. Reads stdin, writes stdout."""
import sys, json

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except:
        continue
    t = msg.get('type', '')
    if t == 'assistant' and 'message' in msg:
        for block in msg['message'].get('content', []):
            if block.get('type') == 'tool_use':
                name = block.get('name', '?')
                inp = block.get('input', {})
                if name == 'Bash':
                    detail = inp.get('command', '?')[:120]
                elif name in ('Write', 'Edit', 'Read'):
                    detail = inp.get('file_path', '?')
                elif name.startswith('mcp__'):
                    parts = [str(v)[:60] for v in inp.values()]
                    detail = ', '.join(parts)[:150]
                elif name == 'Agent':
                    detail = inp.get('description', '?')
                else:
                    detail = str(inp)[:100]
                print(f'  TOOL | {name} | {detail}', flush=True)
            elif block.get('type') == 'text':
                text = block['text'].strip()
                if text:
                    for ln in text.split('\n')[:3]:
                        print(f'  TEXT | {ln[:150]}', flush=True)
    elif t == 'user' and 'message' in msg:
        for block in msg['message'].get('content', []):
            if block.get('type') == 'tool_result':
                is_error = block.get('is_error', False)
                content = block.get('content', '')
                if isinstance(content, list):
                    text = content[0].get('text', '') if content else ''
                else:
                    text = str(content)
                if is_error:
                    print(f'  ERR  | {text[:200]}', flush=True)
                else:
                    first = text.split('\n')[0][:150]
                    print(f'    ok | {first}', flush=True)
    elif t == 'result':
        cost = msg.get('total_cost_usd', msg.get('cost_usd', 0))
        duration = msg.get('duration_ms', 0)
        is_error = msg.get('is_error', False)
        subtype = msg.get('subtype', '')
        prefix = 'FAIL' if is_error else 'DONE'
        print(f'  {prefix} | cost=${cost:.4f} duration={duration/1000:.1f}s subtype={subtype}', flush=True)
