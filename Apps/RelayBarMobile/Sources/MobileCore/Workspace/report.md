# Evaluation summary

Three prompt templates were compared over 48 samples.

## Results

Reviewers preferred template B in 31 of 48 comparisons, most clearly on posters with long headlines.

| Template | Preferred | Share |
| :--- | ---: | ---: |
| A · plain | 9 | 19% |
| B · layout first | 31 | 65% |
| C · style first | 8 | 17% |

## Reproduce

```sh
python eval.py --templates a,b,c --samples 48
```

## Preference rate

For template B, the share of preferred comparisons was

$$
p_B = \frac{31}{48} \approx 0.65
$$

![Two-colour concert poster](samples/grid-0031.png)
