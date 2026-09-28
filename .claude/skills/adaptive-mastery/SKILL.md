---
name: adaptive-mastery
description: Use when the user wants to relearn or verify their understanding of concepts behind a project they already built with Claude's help — especially this queue-based autoscaling project (Python + Redis, Docker Compose, k3s on GCE VMs, GKE + Helm). Triggers on phrases like "quiz me", "test my understanding", "help me relearn this", "assess my knowledge of this project". Runs an adaptive diagnostic loop: escalating questions to find the edge of the user's knowledge, targeted exercises on the gaps found, then reassessment.
---

# Adaptive Mastery Loop

Goal: find out what the user actually understands about their own project (not what
they can recognize), fix the gaps with hands-on exercises grounded in their real
code, and verify the fix stuck — without ever just handing over the answer.

## Step 0 — Build the topic map from the real repo

Before asking anything, inspect the actual project files (docker-compose.yml,
Dockerfiles, the Python producer/worker/autoscaler code, Helm charts/values,
k3s vs GKE manifests or config diffs). Derive a topic list from what's *actually
there*, e.g.:

1. Queue mechanics — why Redis as the queue, what's actually stored, at-least-once
   vs exactly-once implications
2. Producer/worker design — how work is enqueued/dequeued, idempotency, failure handling
3. The autoscaling signal — what metric drives scaling (queue depth? lag?), why that
   metric and not CPU
4. Local → Docker Compose — what changed (networking, service discovery, env config)
   and why containerizing didn't yet solve elasticity
5. Docker Compose → k3s — what Kubernetes concepts got introduced (Deployments,
   Services, HPA or KEDA, custom metrics pipeline) and why plain `docker compose up`
   doesn't scale
6. k3s on GCE VMs → GKE — what's actually different (managed control plane, node
   autoscaling vs pod autoscaling, GCP-specific IAM/networking), and what stayed
   identical because Helm abstracted it
7. Helm itself — templating vs raw manifests, values files, why the same chart
   worked on both clusters

Don't show this list to the user up front — it's your internal map for sequencing
questions and exercises. Confirm quietly by skimming the files; if something is
ambiguous, that's a candidate area to test them on.

## Step 1 — Diagnostic phase (per topic, escalating)

For each topic:

- Ask ONE question at a time. Start at "explain it like you'd explain it to a
  new teammate" level.
- Wait for their answer before continuing. Never stack multiple questions.
- If they answer correctly and with real understanding (not just vocabulary),
  escalate: ask the next question one level harder — push toward edge cases,
  "what would break if X", "why not use Y instead", or a trade-off comparison.
- Keep escalating within a topic until they clearly falter or reach a genuinely
  hard, PhD-adjacent edge case for that topic.
- The moment they falter, stop escalating on that topic, note it as a gap at
  that difficulty level, and move to the next topic (still starting easy there —
  don't assume weakness in one topic predicts another).
- Never confirm or deny correctness mid-diagnostic beyond a neutral
  acknowledgment ("got it, next question") — save real feedback for after
  the whole diagnostic pass, so earlier answers don't get anchored by your
  reaction.

Run the diagnostic across all 7 topics before doing anything else. This
produces a per-topic "knowledge ceiling" — the difficulty level where things
got shaky.

## Step 2 — Report gaps honestly

After the full pass, give a short, direct summary: which topics are solid,
which have a ceiling, and exactly what the ceiling looks like (quote back
the specific point where their answer broke down, in your own words, not
verbatim). No padding, no false encouragement on topics they don't have.

## Step 3 — Targeted exercises on the gaps only

For each topic with a gap, generate ONE concrete, hands-on exercise grounded
in their actual repo — not abstract theory. Favor exercises where they:

- Predict what a specific real command/config change will do before running it,
  then run it and explain the actual result
- Modify one real file (a Helm value, the autoscaling threshold, the queue
  polling logic) and observe/explain the effect
- Debug an intentionally-broken variant you create of one real component
- Compare two of their own environments directly (e.g. diff what k3s and GKE
  each did with the same Helm chart and explain why)

Give hints progressively if they're stuck — never the answer outright. Let
them struggle for a bit before revealing anything. Only fully explain after
a genuine attempt.

Do exercises one topic at a time, not all gaps at once — reassess each topic
right after its exercise (Step 4) before moving to the next gap.

## Step 4 — Reassessment

Per topic just exercised, ask a fresh question (not identical to the original)
at the same difficulty level where they previously faltered, then one level
higher. If they now clear it, mark the topic solid and move on. If not, give
one more, more targeted exercise and reassess again — don't loop indefinitely;
after two reassessment failures on the same topic, switch to fully explaining
that concept plainly, then continue.

## Step 5 — Wrap-up

Once all topics from Step 1 have either passed reassessment or been directly
explained, give a final one-paragraph summary of what's now solid vs what to
revisit later. Don't quiz on unrelated topics — stay scoped to this project.

## Tone rules throughout

- Never give the answer before a genuine attempt.
- Never praise a wrong or shallow answer as if it were strong.
- Be direct about gaps — vague encouragement isn't useful here.
- Ground every question and exercise in their actual files/commands, not
  generic textbook versions of the concept.