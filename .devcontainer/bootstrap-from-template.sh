#!/usr/bin/env bash
#
# bootstrap-from-template.sh
#
# AI USE DISCLOSURE: This file contains portions authored by Claude Code. 
#
# If the currently opened repository looks like a template, offer to create a
# new GitHub repository, detach `origin`, and re-point the working copy at it.
#

set -uo pipefail
 
WORKSPACE="${1:-$PWD}"
MARKER_FILE="${HOME}/.template-bootstrap-answered"
 
c_blue=$'\033[1;34m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_off=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_blue"   "$c_off" "$*"; }
warn() { printf '%s !!%s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die()  { printf '%s xx%s %s\n' "$c_red"    "$c_off" "$*" >&2; exit 1; }
 
cd "$WORKSPACE" 2>/dev/null || exit 0
 
# Only nag once per codespace.
[ -f "$MARKER_FILE" ] && exit 0
 
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
 
# ---------------------------------------------------------------------------
# 1. Work out which repository we are sitting in
# ---------------------------------------------------------------------------
slug="${GITHUB_REPOSITORY:-}"
if [ -z "$slug" ]; then
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  [ -n "$origin_url" ] || exit 0
  # git@host:owner/repo.git | https://host/owner/repo.git -> owner/repo
  slug="$(printf '%s\n' "$origin_url" \
          | sed -E 's#^(git@|ssh://git@|https?://)[^/:]+[:/]##; s#\.git$##')"
fi
owner="${slug%%/*}"
name="${slug#*/}"
 
# ---------------------------------------------------------------------------
# 2. Does it look like a template?
# ---------------------------------------------------------------------------
is_template=0
shopt -s nocasematch
[[ "$name" == *template* ]] && is_template=1
shopt -u nocasematch
 
# Also honour GitHub's own "template repository" flag.
if [ "$is_template" -eq 0 ] && command -v gh >/dev/null 2>&1; then
  [ "$(gh repo view "$slug" --json isTemplate -q .isTemplate 2>/dev/null)" = "true" ] \
    && is_template=1
fi
 
[ "$is_template" -eq 1 ] || exit 0
 
# ---------------------------------------------------------------------------
# 3. Bail out politely if we have no terminal to prompt on
# ---------------------------------------------------------------------------
if [ ! -t 0 ]; then
  warn "You currently have the template repository ($slug) opened."
  warn "Run 'bash .devcontainer/bootstrap-from-template.sh' in a terminal to fork it."
  exit 0
fi
 
command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is not installed in this container."
 
echo
log "You currently have the template repository opened: ${slug}"
read -r -p "Do you want to create a new repository? [y/N] " reply
case "$reply" in
  [yY]|[yY][eE][sS]) ;;
  *) : > "$MARKER_FILE"; log "Keeping the template repository. Won't ask again."; exit 0 ;;
esac
 
# ---------------------------------------------------------------------------
# 4. Collect the details
# ---------------------------------------------------------------------------
new_name=""
while [ -z "$new_name" ]; do
  read -r -p "New repository name: " new_name
  # GitHub allows letters, digits, '.', '-', '_'
  if [ -n "$new_name" ] && ! [[ "$new_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    warn "Only letters, digits, '.', '-' and '_' are allowed."
    new_name=""
  fi
done
 
read -r -p "Owner [${owner}]: " new_owner
new_owner="${new_owner:-$owner}"
full="${new_owner}/${new_name}"
 
visibility=""
while [ -z "$visibility" ]; do
  read -r -p "Visibility - (p)rivate, p(u)blic, (i)nternal [p]: " v
  case "${v:-p}" in
    p|private)  visibility="private"  ;;
    u|public)   visibility="public"   ;;
    i|internal) visibility="internal" ;;
    *) warn "Please answer p, u or i." ;;
  esac
done
 
read -r -p "Start from a clean git history (drop all template commits)? [y/N] " fresh_reply
fresh_history=0
case "$fresh_reply" in [yY]|[yY][eE][sS]) fresh_history=1 ;; esac
 
read -r -p "Create ${full} (${visibility}) and re-point origin at it? [y/N] " confirm
case "$confirm" in
  [yY]|[yY][eE][sS]) ;;
  *) log "Aborted. Nothing was changed."; exit 0 ;;
esac
 
# ---------------------------------------------------------------------------
# 5. Create the repository
# ---------------------------------------------------------------------------
log "Creating ${full} ..."
if ! gh repo create "$full" "--${visibility}" >/dev/null; then
  warn "Could not create the repository."
  warn "The default Codespaces token is scoped to this repo only. Try:"
  warn "    unset GITHUB_TOKEN GH_TOKEN && gh auth login -s repo -w"
  warn "then re-run this script."
  exit 1
fi
 
new_url="$(gh repo view "$full" --json url -q .url 2>/dev/null)"
new_url="${new_url:-https://github.com/${full}}"
 
# ---------------------------------------------------------------------------
# 6. Detach the old remote, attach the new one
# ---------------------------------------------------------------------------
branch="$(git symbolic-ref --quiet --short HEAD || echo main)"
 
if [ "$fresh_history" -eq 1 ]; then
  log "Re-initialising git history on branch '${branch}' ..."
  rm -rf .git
  git init -b "$branch" >/dev/null
  git add -A
  git -c user.name="${GIT_AUTHOR_NAME:-$(git config --global user.name || echo Codespace)}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-$(git config --global user.email || echo codespace@users.noreply.github.com)}" \
      commit -q -m "Initial commit (from ${slug})"
else
  log "Keeping history; moving old origin to remote 'template' ..."
  git remote remove template 2>/dev/null || true
  old_url="$(git remote get-url origin 2>/dev/null || true)"
  [ -n "$old_url" ] && git remote add template "$old_url"
fi
 
git remote remove origin 2>/dev/null || true
git remote add origin "${new_url}.git"
 
log "Pushing '${branch}' to ${full} ..."
if git push -u origin "$branch"; then
  : > "$MARKER_FILE"
  echo
  log "Done. origin now points at ${new_url}"
  [ "$fresh_history" -eq 0 ] && log "The template is still available as the 'template' remote."
  echo
  warn "This Codespace still belongs to ${slug} in the Codespaces service."
  warn "Open a new Codespace on ${full} when you're ready to work there."
else
  warn "Push failed. origin is set to ${new_url} - push manually with:"
  warn "    git push -u origin ${branch}"
  exit 1
fi
