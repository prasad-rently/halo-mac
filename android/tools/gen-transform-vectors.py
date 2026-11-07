#!/usr/bin/env python3
"""Regenerates docs/specs/text-transform-vectors.v1.json by RUNNING the desktop actions' own shell pipelines.

The desktop's text transforms are not Swift functions — they are shell scripts embedded in
Halo/Core/Actions/ActionLibrary.swift and run by `/bin/zsh -c` (LC_ALL unset in a GUI app => C locale). So the fixture is
generated, not hand-written: each script is extracted VERBATIM from the Swift source, `pbpaste`/`pbcopy` are replaced
by shell functions that read the case input / capture what would have reached the clipboard, and the script is run.

    ./gen-transform-vectors.py [path/to/ActionLibrary.swift]    # default: git show origin/release/v2.6:...

JSON cases run only the Python half (`python3 -m json.tool` / `json.dumps`): the scripts' trailing `echo "$RESULT" | pbcopy`
goes through zsh's escape-interpreting echo, which rewrites `\\n` and `\\uXXXX` in the output (a desktop bug recorded in the
fixture's "knownDesktopBugs"; the intended semantic is what json.tool printed, and that is what the phone must match).
"""
import json, os, re, subprocess, sys, tempfile, textwrap

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = sys.argv[1] if len(sys.argv) > 1 else None
swift = open(SRC).read() if SRC else subprocess.check_output(
    ["git", "-C", ROOT, "show", "origin/release/v2.6:Halo/Core/Actions/ActionLibrary.swift"], text=True)

def script_of(name):
    m = re.search(r'name: "%s".*?\.shell\("""\n(.*?)"""\)' % re.escape(name), swift, re.S)
    if not m: raise SystemExit("action not found: " + name)
    body = textwrap.dedent(m.group(1)).replace("\\\\", "\\")
    return body

ACTIONS = {
    "count_words": "Count Words in Clipboard", "sort_lines": "Sort Clipboard Lines", "url_encode": "URL Encode Clipboard",
    "url_decode": "URL Decode Clipboard", "base64_encode": "Base64 Encode Clipboard", "base64_decode": "Base64 Decode Clipboard",
    "uppercase": "Convert Clipboard to UPPERCASE", "lowercase": "Convert Clipboard to lowercase", "dedup_lines": "Remove Duplicate Lines",
    "strip_formatting": "Strip Formatting from Clipboard", "sha256": "Hash Clipboard (SHA-256)",
}

def run_script(key, text):
    out = tempfile.NamedTemporaryFile(delete=False); out.close()
    pre = 'pbpaste() { printf %%s "$HALO_IN"; }; pbcopy() { cat > "%s"; }\n' % out.name
    env = dict(os.environ, LC_ALL="C", LANG="C", HALO_IN=text)
    r = subprocess.run(["/bin/zsh", "-c", pre + script_of(ACTIONS[key])], env=env, capture_output=True, text=True)
    data = open(out.name, "rb").read().decode("utf-8", "surrogateescape"); os.unlink(out.name)
    return r.stdout, data

def clip_of(key, text):
    stdout, clip = run_script(key, text)
    if "\u26a0" in stdout: return None          # the script printed its warning and left the clipboard alone: a failure
    if key == "count_words":                   # reports to stdout, nothing on the clipboard
        return stdout.rstrip("\n")
    return clip[:-1] if clip.endswith("\n") else clip     # `echo "$X" | pbcopy` adds one newline

def json_format(text):
    r = subprocess.run(["python3", "-m", "json.tool"], input=text, capture_output=True, text=True, env=dict(os.environ, LC_ALL="C"))
    return r.stdout.rstrip("\n") if r.returncode == 0 else None

def json_minify(text):
    code = "import json, sys; data=json.load(sys.stdin); print(json.dumps(data, separators=(',',':')))"
    r = subprocess.run(["python3", "-c", code], input=text, capture_output=True, text=True, env=dict(os.environ, LC_ALL="C"))
    return r.stdout.rstrip("\n") if r.returncode == 0 else None

# NOTE: echo-based scripts run under zsh, whose echo interprets backslash sequences, so inputs for those contain none.
CASES = [
    ("format_json", "{\"b\":1,\"a\":[1,2,{\"c\":null}],\"d\":\"x\"}"),
    ("format_json", "[]"), ("format_json", "{}"), ("format_json", "{\"k\":\"café ☃ \U0001F600\"}"),
    ("format_json", "{\"a\":\"line\\nbreak \\\"quoted\\\" \\\\ back\\t\"}"),
    ("format_json", "{\"n\":[1,-2,3.5,0.25,100,true,false,null],\"e\":{},\"l\":[]}"),
    ("format_json", "{\"a\":1,\"a\":2,\"b\":3}"), ("format_json", "42"), ("format_json", "\"s\""),
    ("minify_json", "{\n  \"b\": 1,\n  \"a\": [1, 2, {\"c\": null}]\n}"), ("minify_json", "{\"k\":\"café \U0001F600\"}"), ("minify_json", "[ ]"),
    ("count_words", "hello world"), ("count_words", "one\ntwo three\n\nfour"), ("count_words", "  spaced   out\ttabs  "), ("count_words", "trailing newlines\n\n\n"),
    ("count_words", "a"), ("count_words", "café"),
    ("sort_lines", "pear\napple\nbanana"), ("sort_lines", "b\nB\na\nA\n10\n9\n_x"), ("sort_lines", "z\nz\na"), ("sort_lines", "single"),
    ("sort_lines", "\U0001F600\n\uff5e\nz"),
    ("format_json", "{bad json"), ("format_json", "{\"a\":1,}"), ("minify_json", "not json"),
    ("sort_lines", "éclair\nzebra\nApple\nemoji \U0001F600\nplain"),
    ("url_encode", "hello world & friends=100%"), ("url_encode", "a/b/c?d=e f"), ("url_encode", "  trimmed  "), ("url_encode", "café ☃ \U0001F600"),
    ("url_encode", "keep-_.~ and /slash"), ("url_encode", "plus+sign"),
    ("url_decode", "hello%20world%20%26%20friends%3D100%25"), ("url_decode", "caf%C3%A9%20%E2%98%83%20%F0%9F%98%80"), ("url_decode", "a+b%2"), ("url_decode", "100%"), ("url_decode", "%zz%41"),
    ("base64_encode", "hello"), ("base64_encode", "hello world!"), ("base64_encode", "café \U0001F600"), ("base64_encode", "a"), ("base64_encode", "ab"), ("base64_encode", "two\nlines"),
    ("base64_decode", "aGVsbG8="), ("base64_decode", "aGVsbG8gd29ybGQh"), ("base64_decode", "!!!not base64!!!"), ("base64_decode", "Y2Fmw6kg8J+YgA=="), ("base64_decode", "YQ=="),
    ("uppercase", "Hello World 123"), ("uppercase", "already UPPER"), ("lowercase", "Hello World 123"), ("lowercase", "ALREADY lower"),
    ("dedup_lines", "a\nb\na\nc\nb"), ("dedup_lines", "x\nx\nx"), ("dedup_lines", "a\n\nb\n\nc"), ("dedup_lines", "unique\nlines\nonly"),
    ("strip_formatting", "plain text stays"), ("strip_formatting", "keeps\nlines  and   spaces"),
    ("sha256", "hello"), ("sha256", "café \U0001F600"), ("sha256", "two\nlines"), ("sha256", "abc"),
]

cases = []
for i, (key, text) in enumerate(CASES):
    if key == "format_json": exp = json_format(text)
    elif key == "minify_json": exp = json_minify(text)
    else: exp = clip_of(key, text)
    cases.append({"id": "%s-%02d" % (key, i), "transform": key, "input": text, "expected": exp})

# Cases whose input has a trailing newline: the desktop strips it ($(pbpaste)), and so must the phone.
for key, text in [("sha256", "hello\n"), ("base64_encode", "hello\n\n"), ("count_words", "x y\n")]:
    cases.append({"id": "%s-trailing-newline" % key, "transform": key, "input": text, "expected": clip_of(key, text)})

py = subprocess.check_output(["python3", "--version"], text=True).strip()
doc = {
    "version": 1,
    "about": "Input -> expected pairs for the deterministic text transforms, produced by running the desktop action scripts (see android/tools/gen-transform-vectors.py). Consumed by halotools' TransformVectorsTest; a Swift/desktop consumer is not applicable because the desktop logic is shell, not Swift.",
    "generated": {"python": py, "locale": "C (LC_ALL=C; a GUI app has no LANG)", "shell": "/bin/zsh -c", "source": "Halo/Core/Actions/ActionLibrary.swift @ origin/release/v2.6"},
    "comparison": "expected null means the desktop action reported a failure (and left the clipboard untouched). expected has ONE trailing newline removed where the script ends in `echo ... | pbcopy`; count_words expected is the script's stdout report (its 'Characters' is wc -c = BYTES, equal to code points for these ASCII cases and compared as bytes).",
    "knownDivergences": [
        "format/minify JSON: number tokens are kept verbatim on the phone; Python re-renders floats (1E5 -> 100000.0). Cases here use only numbers that print identically.",
        "uppercase/lowercase: desktop `tr` is ASCII-only; the phone is Unicode-aware (straSSe). Cases here are ASCII.",
        "count_words: phone also reports Unicode characters and bytes; desktop 'Characters' is bytes.",
        "base64_decode: phone also accepts URL-safe alphabet and missing padding; macOS base64 does not.",
        "generate UUID: phone and macOS uuidgen are both upper-case v4; random so asserted by shape only."
    ],
    "knownDesktopBugs": [
        "zsh's builtin echo interprets backslash escapes. Every script that ends `echo \"$RESULT\" | pbcopy` (Format JSON, Sort, Dedup, Count) corrupts text containing \\n, \\t, \\uXXXX, \\\\ before it reaches the clipboard. The phone implements the intended semantic."
    ],
    "properties": {"uuid": "^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$", "password": "^[A-Za-z0-9]{20}$"},
    "cases": cases,
}
dest = os.path.join(ROOT, "docs", "specs", "text-transform-vectors.v1.json")
json.dump(doc, open(dest, "w"), indent=2, ensure_ascii=False); open(dest, "a").write("\n")
print("wrote", dest, len(cases), "cases")
