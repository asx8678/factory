#!/bin/sh
# Started by pi-acp in place of pi (PI_ACP_PI_COMMAND, set by Factory.Runtime): pi as
# Factory runs it. Without the person's own extensions, skills and prompt templates,
# which would write into replies, but with Factory's extension (its tools, and asking
# Factory before each tool) and the one that brings the chosen model's provider.
set -e

extensions=""
old_ifs=$IFS
IFS=:
for extension in $FACTORY_PI_EXTENSIONS; do
  [ -n "$extension" ] && extensions="$extensions
$extension"
done
IFS=$old_ifs

# The arguments pi-acp gave, then Factory's. A newline never appears in these paths.
# Nothing is kept as a pi session: Factory's turns don't belong among the person's own.
set -- "$@" --no-session --no-extensions --no-skills --no-prompt-templates
IFS='
'
for extension in $extensions; do
  [ -n "$extension" ] && set -- "$@" --extension "$extension"
done
IFS=$old_ifs

# "provider/model", as pi lists them; none means pi's own default.
if [ -n "$FACTORY_PI_MODEL" ]; then
  set -- "$@" --model "$FACTORY_PI_MODEL"
fi

exec "${FACTORY_PI:-pi}" "$@"
