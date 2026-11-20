# Retrieval ablation, round 3

Which retrieved exemplars earn their place? Dropping layout exemplars costs nine points of preference. Dropping palette exemplars costs almost nothing. Most of the loss is on briefs with a long headline.

## Setup

We compared four retrieval conditions on the same 48 poster briefs.

### Briefs and split

The held-out set includes narrow columns, portrait images and long headlines.

### Conditions

We removed one class of exemplar at a time and kept the generator settings fixed.

## Results

### Win rate by condition

| Condition | Preferred | Win rate |
| --- | ---: | ---: |
| No layout exemplars | 59 of 144 | 41% |
| No typography exemplars | 64 of 144 | 45% |
| No palette exemplars | 70 of 144 | 49% |
| No retrieval | 46 of 144 | 32% |

### Where layout exemplars help

Nearly all of the loss comes from two kinds of brief. On the other 30 briefs the two conditions are level, 45 wins each.

![Poster study, full retrieval and without layout exemplars](figures/comparison.png)

#### Long headlines that wrap past two lines

Without a layout exemplar the generator keeps the headline in one column and lets it run down the page. Raters preferred the full-retrieval poster on 14 of these 18 briefs.

#### Portrait briefs with a dominant image

The image grows to fill the page and the headline is squeezed into a thin band at the top edge.

### Palette exemplars are nearly free to drop, even on long briefs

Raters split almost evenly. The generator borrows colour from the wording of the brief even without the palette exemplar.

## Failure cases

### Headings running into the image

Long captions need extra clearance around the subject.

### Repeated palettes across different briefs

The repeated red and green pair was easy to recognize in adjacent samples.

## Reproduce

Keep the briefs, split and seeds fixed when comparing the next round.
