#!/usr/bin/env python3
"""Render the matched SQLodin follow-up from complete baseline/candidate JSON reports."""
import argparse
import json
from pathlib import Path
import statistics
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--results',type=Path,default=Path('benchmarks/results/verification-20260924'))
p.add_argument('--output',type=Path,default=Path('docs/book/plots/sqlodin-progress.svg'))
a=p.parse_args()
fig,ax=plt.subplots(figsize=(7.6,3.2))
for offset,label,color in [(-.14,'baseline','#8696a6'),(.14,'progress','#187c8b')]:
    r=json.loads((a.results/f'bench-{label}.json').read_text())
    assert r['complete'] and r['all_samples_passed'] and r['host_address']=='10.175.52.18'
    series=[[x['phases'][i]['operations_per_second'] for x in r['realworld']] for i in range(3)]
    series.append([x['operations_per_second'] for x in r['sequential_writes']])
    for i,values in enumerate(series):
        assert len(values)==3
        m=statistics.median(values)
        ax.errorbar(m,i+offset,xerr=[[m-min(values)],[max(values)-m]],fmt='o',color=color,
                    capsize=3,label=label.capitalize() if i==0 else None)
        ax.annotate(f'{m:.2f}',(m,i+offset),xytext=(7,2),textcoords='offset points',fontsize=8)
ax.set_yticks(range(4),['Healthy mixed SQL','One voter crashed','Entry voter crashed','Sequential writes'])
ax.invert_yaxis();ax.set_xscale('log');ax.set_xlim(1.8,155)
ax.set_xlabel('Completed operations/s (log scale); median and observed range, n=3',fontsize=9)
ax.grid(axis='x',alpha=.2);ax.spines[['top','right']].set_visible(False)
ax.legend(loc='upper right',frameon=False,fontsize=9)
fig.tight_layout();a.output.parent.mkdir(parents=True,exist_ok=True)
fig.savefig(a.output,transparent=True)
