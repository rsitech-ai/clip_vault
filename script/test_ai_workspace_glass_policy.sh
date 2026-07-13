#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AI_PANEL="$ROOT_DIR/Sources/ClipVault/Views/AIActionPanel.swift"

INLINE_TOOLBAR="$(sed -n '/private var inlineActionToolbar:/,/private var actionButtons:/p' "$AI_PANEL")"
COMPACT_ACTIONS="$(sed -n '/private func compactActionButton/,/private var enhancePromptButton:/p' "$AI_PANEL")"
COMPACT_ENHANCE="$(sed -n '/private var compactEnhancePromptButton:/,/private var header:/p' "$AI_PANEL")"
ASK_ROW="$(sed -n '/private var askRow:/,/private var askPlaceholder:/p' "$AI_PANEL")"

if grep -Fq 'ClipVaultGlassContainer' <<<"$INLINE_TOOLBAR"; then
  echo "inline AI actions must not use GlassEffectContainer during persisted-expanded cold launch" >&2
  exit 1
fi

for section in "$COMPACT_ACTIONS" "$COMPACT_ENHANCE"; do
  grep -Fq '.buttonStyle(.plain)' <<<"$section"
  grep -Fq '.clipVaultGlassSurface(' <<<"$section"
  ! grep -Fq '.clipVaultGlassButtonStyle' <<<"$section"
done

grep -Fq 'case .inline:' <<<"$ASK_ROW"
grep -Fq '.buttonStyle(.plain)' <<<"$ASK_ROW"
grep -Fq '.clipVaultGlassSurface(' <<<"$ASK_ROW"

echo "AI workspace glass policy passed"
