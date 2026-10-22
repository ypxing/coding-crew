# yaml_to_json <yaml> <json> — YAML → JSON with whatever parser the machine has: js-yaml for node, else PyYAML.
# Exit 3 when neither exists, the parser's own non-zero exit when the file does not parse.
yaml_to_json() {
  if node -e 'require.resolve("js-yaml")' >/dev/null 2>&1; then
    node -e 'const y=require("js-yaml"),fs=require("fs");fs.writeFileSync(process.argv[2],JSON.stringify(y.load(fs.readFileSync(process.argv[1],"utf8"))))' "$1" "$2"
  elif python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import sys,json,yaml;json.dump(yaml.safe_load(open(sys.argv[1])),open(sys.argv[2],"w"))' "$1" "$2"
  else
    return 3
  fi
}
