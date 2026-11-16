# Sampler run 14 — notes

A *short* report with **bold**, ~~struck~~ text, `inline code`, a [link](https://example.com) and a bare URL: https://example.com/runs/14.

## Checklist

- [x] Seeds fixed for all eight prompts
- [ ] Re-run the two failures
  - [ ] `cfg 7.5`, 30 steps
  - [x] `cfg 5.0`, 40 steps
- Plain item with a nested list
  1. first
  2. second

## Results

| Prompt | Steps | CFG | Seed | Verdict |
| :-- | --: | --: | --: | :-- |
| harbour at dusk | 30 | 7.5 | 1184 | keep |
| paper lantern, macro | 40 | 5.0 | 2291 | redo — hands |
| long-column table to test width, with a much longer description cell | 30 | 7.5 | 77 | keep |

## Code

```python
def schedule(steps: int, sigma_max: float = 14.6) -> list[float]:
    # Karras-style spacing
    return [sigma_max * (1 - i / steps) ** 7 for i in range(steps)]
```

```
no language given: plain block with a long line that should scroll rather than wrap ............................................
```

> Quoted remark: the lantern set needs a lower CFG.
> It continues on a second line.

![Colour bands from the run](diagram.png)

---

Final paragraph after a rule.
