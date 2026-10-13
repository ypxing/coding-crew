# syntax=docker/dockerfile:1
# A sandbox that runs solve-feature on a clone with claude, copilot, pi or codex, coding-crew
# installed user-level for every platform. Build and run from the project's clone:
#
#   docker build -t solve-feature -f .coding-crew/solve-feature/hosts/Dockerfile .
#   docker run --rm -v "$PWD":/work -w /work \
#     -e ANTHROPIC_API_KEY \                      # --agent claude; --agent pi on its Anthropic provider
#     -e OPENAI_API_KEY \                         # --agent codex; --agent pi on its OpenAI provider
#     -e GH_TOKEN \                               # the tracker and the PR; the coder for --agent copilot
#     -v /var/run/docker.sock:/var/run/docker.sock --group-add "$(stat -c %g /var/run/docker.sock)" \
#     solve-feature bash "$HOME/.coding-crew/solve-feature/scripts/solve-feature.sh" <slug> --agent claude
#
# The docker socket line is for a project whose checks run in compose (dep-install's docker mode
# nests nothing: a command that runs docker itself is run as is); drop it otherwise. pi takes any
# provider's key its README lists (https://github.com/earendil-works/pi): pass the one for the model
# set in afk.models.pi.
# The branch is pushed and the PR opened from inside the container, so the clone's `origin` has
# to be reachable with GH_TOKEN (an https remote), and the clone needs a committed
# .coding-crew/dev-commands.json.
FROM node:22-bookworm

# The coding-crew ref to install. Pin it to the first tag cut after solve-feature's hosts
# shipped (no tag before that has review-pr); `main` until then.
ARG CODING_CREW_REF=main

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg git jq coreutils \
  && install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
  && apt-get update && apt-get install -y --no-install-recommends gh docker-ce-cli docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code @github/copilot @openai/codex @earendil-works/pi-coding-agent

# Not root: claude refuses bypassPermissions as root, and the coder runs with every permission.
RUN useradd -m -s /bin/bash crew
USER crew
ENV HOME=/home/crew
WORKDIR /home/crew

# A mounted clone is owned by the host user, which git otherwise refuses as "dubious ownership".
RUN git config --global --add safe.directory '*' \
  && git clone --depth 1 --branch "$CODING_CREW_REF" https://github.com/ypxing/coding-crew /tmp/coding-crew \
  && TARGET_REPO="$HOME" bash /tmp/coding-crew/install.sh all --skills solve-feature,review-pr \
  && rm -rf /tmp/coding-crew

WORKDIR /work
