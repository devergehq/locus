# Image Generation Workflow

Generate and iterate on images via platform-native image generation (Nano Banana Pro, Flux, GPT-Image-1, etc.). Prompt engineering, model selection, composition, editorial judgement.

## When to use

- Header images, hero illustrations, editorial visuals.
- Concept illustrations where structure matters (not just "any stock-like image").
- Iterative image work — generate, evaluate, refine.

Not for: programmatic data visualisation (use Mermaid / D3 / equivalent), stock photography (use a stock service), AI-avatar/character generation (out of Locus scope).

## Model selection

| Model            | Strengths                                                  | When to pick                                              |
|------------------|------------------------------------------------------------|-----------------------------------------------------------|
| Nano Banana Pro  | Fast iteration, stylistic range, cheap per-image           | Iterative editorial work, style exploration               |
| Flux (variants)  | Photorealism, physical scenes, lighting                    | Realistic imagery, product shots, photography pastiche    |
| GPT-Image-1      | Text-heavy images, typography, mixed-media                 | Images with readable text, typography-driven designs      |

Default to Nano Banana Pro for iterative work unless the task demands a strength one of the others has.

## Prompt engineering

A good prompt names:

- **Subject** — what is in the frame
- **Style** — photo, illustration, line art, woodcut, etc.
- **Composition** — close / wide, angle, framing
- **Lighting** — soft, hard, time of day, source
- **Colour palette** — warm / cool / specific hex range
- **Negative space** — where empty space sits in the frame
- **Mood** — what the image should feel like
- **Exclusions** — what must not appear ("no text", "no faces")

Short prompts produce generic output. Specific prompts produce specific output.

## Iteration

Never accept the first generation as final. The workflow is:

1. Write the prompt.
2. Generate (typically 2-4 variations).
3. **Inspect each generated image** — actually view the file, describe what you see. Never describe an image you have not viewed.
4. Compare against intent.
5. Refine the prompt based on what the images actually show vs what was intended.
6. Regenerate.
7. Repeat until the image matches intent or you hit the iteration budget.

## Output

```markdown
## Image Generation: <intent>

### Prompt (final)
<the prompt that produced the chosen image>

### Model
<model used>

### Iterations
- Iteration 1: <what prompt, what came back, what was wrong>
- Iteration 2: <what changed, what came back>
- ...

### Selected image
<path to the final image file>

### Provenance
Model: <model>, parameters: <seed, guidance scale, etc. if relevant>. Prompt: <verbatim final prompt>.
```

## Anti-patterns

- **"Generate an image of X"** with no style, composition, or mood guidance — produces generic AI-look output.
- **Skipping inspection.** Never claim an image matches intent if you have not viewed it.
- **Manufacturing detail that isn't in the image.** Describe what is there, not what was hoped for.
- **Stopping at the first acceptable output.** "Acceptable" is rarely good; iterate at least twice.

## Composition

Image generation pairs well with:

- **creative** skill — specificity and constraint principles apply directly to prompt writing.
- **artist agent archetype** — `agents/artist.md` gives the role, trait stance, and iteration discipline.
