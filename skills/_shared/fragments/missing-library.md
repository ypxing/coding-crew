**Shared scripts.** The scripts this skill runs live in the `coding-crew-lib` skill, installed beside it at
`<skill-dir>/../coding-crew-lib` (`<skill-dir>` being the directory you read this file from). Before the first
command that runs one, check that directory exists. If it does not, stop and tell the user to install it at this
skill's scope, `npx skills add ypxing/coding-crew -s coding-crew-lib` (adding `-g` when this skill is installed at
user level), or to re-run coding-crew's `install.sh`.
