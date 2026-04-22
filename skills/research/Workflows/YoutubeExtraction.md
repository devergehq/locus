# YouTube Extraction Workflow

**Fetch a YouTube video's transcript and run a research-grade analysis on it.**

## When to use

- User provides a YouTube URL and wants the content analysed (not just "summarise it").
- Research task references a talk, interview, or tutorial video as a source.
- Building a knowledge extract from video content (see `ExtractKnowledge.md`).

## Transcript fetch

YouTube transcripts are fetched via the platform's available mechanism:

- **If a platform-native tool exists** (e.g., a YouTube transcript MCP), use it directly.
- **Otherwise** — fetch the `youtubei` or `timedtext` transcript endpoint for the video ID, or use the platform's browser automation to extract the transcript from the YouTube UI.

If no transcript is available (auto-generated only, and the auto-generation has failed or is disabled), document the failure and degrade: analyse what metadata is available (title, description, chapter markers, public comments) and flag the limitation in the output.

## Execution

### Step 1 — Normalise the URL

Accept any YouTube URL form (`youtube.com/watch?v=X`, `youtu.be/X`, `youtube.com/shorts/X`, `youtube.com/live/X`). Extract the video ID.

### Step 2 — Fetch metadata

Title, channel, published date, duration, description. This grounds the analysis — you can refer to speaker attribution and give temporal context.

### Step 3 — Fetch transcript

Get the full transcript text. Preserve timestamps if available — timestamp-anchored quotes are significantly more useful for later reference.

### Step 4 — Choose the analysis mode

Depending on the caller's intent:

| Intent                                         | Downstream workflow                   |
|------------------------------------------------|---------------------------------------|
| "Summarise this video"                          | (use `extract-wisdom` skill instead)  |
| "What are the highest-signal insights?"         | `Workflows/ExtractAlpha.md`           |
| "Extract structured knowledge from this talk"   | `Workflows/ExtractKnowledge.md`       |
| "Prep me to interview this person"              | `Workflows/Interview.md`              |

Or run a direct analysis if the intent is bespoke.

### Step 5 — Analyse

Apply the chosen workflow to the transcript. Treat the transcript as the source; quote with timestamps where possible.

### Step 6 — Verify

- Any external URLs cited in the video's claims need verification per `UrlVerificationProtocol.md`.
- The video URL itself is verified by the successful fetch.

### Step 7 — Output

```markdown
## YouTube Extraction: <Title>

**Channel:** <channel>
**Published:** <date>
**Duration:** <duration>
**URL:** <verified video URL>

### Summary
<1-paragraph overview — not the primary deliverable, just orientation>

### <Analysis section per chosen mode>
<content per the downstream workflow>

### Timestamp-anchored quotes
- <HH:MM:SS> "<quote>"
- ...

### Verified external sources (claims from the video)
- <URL 1> — verified
- ...
```

## Anti-patterns

- **Summarising without analysis.** A summary is a compression; if that's all the caller wanted, a simpler tool suffices.
- **Hallucinating timestamps.** If the timestamp isn't from the actual transcript, don't include it.
- **Skipping external URL verification.** Claims made in a video still need source-check for the URLs cited in support.

## Budget

Transcript fetch: 5-30 seconds. Analysis depends on chosen workflow (see respective workflow's budget). Total typically 1-5 minutes.
