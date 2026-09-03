#!/bin/sh
set -eu

# External backup adapter for Render Free. FilesLink's hosted Rust service
# accepts raw-body uploads and stores them in its configured Telegram channel.
BASE_URL=${FILESLINK_API_BASE_URL:-https://tcloud-2f7u.onrender.com}
CHUNK_BYTES=${FILESLINK_CHUNK_BYTES:-47185920}
BACKUP_PREFIX=${FILESLINK_BACKUP_PREFIX:-openclaw-backup}
WORK_DIR=${FILESLINK_WORK_DIR:-/tmp/openclaw-fileslink}

BASE_URL=$(printf '%s' "$BASE_URL" | sed 's:/*$::')
mkdir -p "$WORK_DIR"

url_encode() {
  node --input-type=module - "$1" <<'NODE'
const value = process.argv[2];
process.stdout.write(encodeURIComponent(value));
NODE
}

upload_file() {
  file=$1
  name=$2
  encoded_name=$(url_encode "$name")
  response=$(curl -fsS --retry 3 --connect-timeout 15 --max-time 900 \
    --data-binary "@$file" \
    "$BASE_URL/api/files/upload?filename=$encoded_name")
  node --input-type=module - "$response" <<'NODE'
const value = JSON.parse(process.argv[2]);
if (!value.success || typeof value.unique_id !== "string") process.exit(2);
process.stdout.write(value.unique_id);
NODE
}

create_backup() {
  backup_id=$(date -u +%Y%m%dT%H%M%SZ)
  run_dir="$WORK_DIR/create-$backup_id"
  output_dir="$run_dir/output"
  chunks_dir="$run_dir/chunks"
  mkdir -p "$output_dir" "$chunks_dir"
  trap 'rm -rf "$run_dir"' EXIT INT TERM

  echo "Creating verified OpenClaw backup: $backup_id"
  openclaw backup create --output "$output_dir" --verify
  archive=$(find "$output_dir" -maxdepth 1 -type f -name '*-openclaw-backup.tar.gz' -print -quit)
  [ -n "$archive" ] || { echo "No backup archive was produced" >&2; exit 1; }

  split -b "$CHUNK_BYTES" -d -a 6 "$archive" "$chunks_dir/part-"
  chunks_json="$run_dir/chunks.jsonl"
  : > "$chunks_json"
  index=0
  for chunk in "$chunks_dir"/part-*; do
    [ -f "$chunk" ] || continue
    size=$(wc -c < "$chunk" | tr -d ' ')
    [ "$size" -le "$CHUNK_BYTES" ] || { echo "Chunk exceeds configured limit" >&2; exit 1; }
    sha=$(sha256sum "$chunk" | awk '{print $1}')
    chunk_name="$BACKUP_PREFIX-$backup_id.part-$(printf '%06d' "$index")"
    echo "Uploading chunk $index ($size bytes)"
    unique_id=$(upload_file "$chunk" "$chunk_name")
    printf '%s\t%s\t%s\t%s\t%s\n' "$index" "$chunk_name" "$size" "$sha" "$unique_id" >> "$chunks_json"
    index=$((index + 1))
  done

  archive_sha=$(sha256sum "$archive" | awk '{print $1}')
  archive_size=$(wc -c < "$archive" | tr -d ' ')
  manifest="$run_dir/$BACKUP_PREFIX-$backup_id.manifest.json"
  node --input-type=module - "$chunks_json" "$manifest" "$backup_id" "$archive_size" "$archive_sha" "$CHUNK_BYTES" "$BASE_URL" "$BACKUP_PREFIX" <<'NODE'
import fs from "node:fs";
const [jsonl, output, backupId, archiveSize, archiveSha, chunkBytes, baseUrl, prefix] = process.argv.slice(2);
const chunks = fs.readFileSync(jsonl, "utf8").trim().split("\n").filter(Boolean).map(line => {
  const [index, name, size, sha256, uniqueId] = line.split("\t");
  return { index: Number(index), name, size: Number(size), sha256, unique_id: uniqueId };
});
fs.writeFileSync(output, JSON.stringify({
  format: 2,
  backup_id: backupId,
  prefix,
  archive_size: Number(archiveSize),
  archive_sha256: archiveSha,
  chunk_bytes: Number(chunkBytes),
  chunks,
  fileslink_base_url: baseUrl,
  created_at: new Date().toISOString(),
}, null, 2) + "\n");
NODE

  manifest_name="$BACKUP_PREFIX-$backup_id.manifest.json"
  echo "Uploading backup manifest"
  upload_file "$manifest" "$manifest_name" >/dev/null
  echo "FilesLink backup completed: $backup_id ($index chunks)"
  trap - EXIT INT TERM
  rm -rf "$run_dir"
}

restore_latest() {
  restore_dir="$WORK_DIR/restore-$$"
  mkdir -p "$restore_dir"
  trap 'rm -rf "$restore_dir"' EXIT INT TERM
  listing=$(curl -fsS --retry 3 --connect-timeout 15 --max-time 120 "$BASE_URL/api/files")
  printf '%s' "$listing" > "$restore_dir/listing.json"
  manifest_info=$(node --input-type=module - "$restore_dir/listing.json" "$BACKUP_PREFIX" <<'NODE'
import fs from "node:fs";
const [listingPath, prefix] = process.argv.slice(2);
const files = JSON.parse(fs.readFileSync(listingPath, "utf8"));
const manifests = files.filter(x => typeof x.file_name === "string" && x.file_name.startsWith(`${prefix}-`) && x.file_name.endsWith(".manifest.json"));
manifests.sort((a, b) => Number(b.uploaded_at ?? 0) - Number(a.uploaded_at ?? 0));
if (manifests[0]) process.stdout.write(`${manifests[0].unique_id}\t${manifests[0].file_name}`);
NODE
  )
  [ -n "$manifest_info" ] || { echo "No FilesLink backup manifest found; starting with empty state."; trap - EXIT INT TERM; rm -rf "$restore_dir"; return 0; }
  tab=$(printf '\t')
  IFS="$tab" read -r manifest_id manifest_name <<EOF
$manifest_info
EOF
  manifest_file="$restore_dir/$manifest_name"
  curl -fsS --retry 3 --connect-timeout 15 --max-time 900 \
    "$BASE_URL/files/$manifest_id?dl=1" -o "$manifest_file"

  node --input-type=module - "$manifest_file" "$restore_dir" "$BASE_URL" <<'NODE'
import fs from "node:fs";
import { execFileSync } from "node:child_process";
const [manifestPath, dir, base] = process.argv.slice(2);
const m = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
for (const chunk of [...m.chunks].sort((a, b) => a.index - b.index)) {
  const out = `${dir}/${chunk.name}`;
  execFileSync("curl", ["-fsS", "--retry", "3", "--connect-timeout", "15", "--max-time", "900", `${base}/files/${chunk.unique_id}?dl=1`, "-o", out]);
  const actual = execFileSync("sha256sum", [out], { encoding: "utf8" }).split(/\s+/)[0];
  if (actual !== chunk.sha256) throw new Error(`Chunk hash mismatch: ${chunk.index}`);
}
const archive = `${dir}/restored-openclaw-backup.tar.gz`;
const fd = fs.openSync(archive, "w");
for (const chunk of [...m.chunks].sort((a, b) => a.index - b.index)) fs.writeSync(fd, fs.readFileSync(`${dir}/${chunk.name}`));
fs.closeSync(fd);
const actual = execFileSync("sha256sum", [archive], { encoding: "utf8" }).split(/\s+/)[0];
if (actual !== m.archive_sha256) throw new Error("Archive hash mismatch");
NODE

  extracted="$restore_dir/extracted"
  openclaw backup restore "$restore_dir/restored-openclaw-backup.tar.gz" --target "$extracted"
  archive_root=$(find "$extracted" -mindepth 1 -type f -name manifest.json -print -quit)
  [ -n "$archive_root" ] || { echo "Restored archive has no manifest.json" >&2; exit 1; }
  archive_root=${archive_root%/manifest.json}
  node --input-type=module - "$archive_root" <<'NODE'
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
const root = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"));
for (const asset of manifest.assets ?? []) {
  if (!asset.sourcePath || !asset.archivePath) continue;
  const source = asset.sourcePath;
  const from = path.join(root, asset.archivePath);
  fs.rmSync(source, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(source), { recursive: true });
  execFileSync("cp", ["-a", from, source]);
}
NODE
  openclaw doctor || true
  echo "FilesLink restore completed"
  trap - EXIT INT TERM
  rm -rf "$restore_dir"
}

case "${1:-backup}" in
  backup) create_backup ;;
  restore) restore_latest ;;
  *) echo "Usage: $0 {backup|restore}" >&2; exit 2 ;;
esac
