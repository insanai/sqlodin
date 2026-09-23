#!/usr/bin/env python3
"""Render publication figures directly from a complete native benchmark report."""
import argparse
import json
from pathlib import Path
import statistics
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

LABELS={'sqlodin':'SQLodin','zaxonlite':'Zaxonlite','rqlite':'rqlite','cowsql':'cowsql demo'}
COLORS={'sqlodin':'#187c8b','zaxonlite':'#586f95','rqlite':'#b37c35','cowsql':'#7a7585'}


def bars(axis, systems, values, title, unit, log=False):
    labels=[]
    for index,system in enumerate(systems):
        samples=values(system); middle=statistics.median(samples)
        labels.append(f'{LABELS[system]} (n={len(samples)})')
        if log: axis.scatter(middle,index,color=COLORS[system],s=55,zorder=3)
        else: axis.barh(index,middle,color=COLORS[system],height=.52)
        axis.errorbar(middle,index,xerr=[[middle-min(samples)],[max(samples)-middle]],
                      fmt='none',ecolor='#263747',capsize=4,lw=1)
        axis.annotate(f'{middle:,.1f}',(middle,index),xytext=(7,0),textcoords='offset points',
                      va='center',fontsize=9)
    axis.set_yticks(range(len(systems)),labels); axis.invert_yaxis()
    axis.set_title(title,loc='left',fontsize=12,fontweight='bold',pad=12)
    axis.set_xlabel(unit,fontsize=9); axis.grid(axis='x',alpha=.18); axis.set_axisbelow(True)
    axis.spines[['top','right','left']].set_visible(False); axis.tick_params(length=0)
    if log: axis.set_xscale('log'); axis.set_xlim(right=axis.get_xlim()[1]*3)
    else: axis.set_xlim(right=axis.get_xlim()[1]*1.22)


def main():
    parser=argparse.ArgumentParser(); parser.add_argument('report',type=Path)
    parser.add_argument('--output',type=Path,default=Path('docs/book/plots'));args=parser.parse_args()
    report=json.loads(args.report.read_text());assert report['complete']
    for group,systems in [('realworld',('sqlodin','zaxonlite','rqlite')),
                          ('sequential_writes',('sqlodin','zaxonlite','rqlite','cowsql'))]:
        for system in systems:
            rows=[r for r in report[group] if r['system']==system]
            failures=[r for r in report.get('failures',[]) if r['group']==group and r['system']==system]
            assert sorted(r['repeat'] for r in rows+failures)==list(range(report['workload']['repeats']))
            assert rows, 'No successful samples available to plot'
    args.output.mkdir(parents=True,exist_ok=True)
    plt.rcParams.update({'font.family':'DejaVu Sans','font.size':10,'svg.fonttype':'path','axes.labelcolor':'#304451',
                         'text.color':'#203744','xtick.color':'#526673','ytick.color':'#304451'})
    def mixed(system,index,metric):
        rows=[r['phases'][index] for r in report['realworld'] if r['system']==system]
        return [r['operations_per_second'] if metric=='rate' else r['latency_ms']['all']['p99'] for r in rows]
    systems=['sqlodin','zaxonlite','rqlite']
    fig,axes=plt.subplots(1,2,figsize=(9.6,3.1),layout='constrained')
    bars(axes[0],systems,lambda s:mixed(s,0,'rate'),'Healthy mixed SQL','Operations / second; higher is better')
    bars(axes[1],systems,lambda s:mixed(s,0,'p99'),'Request p99 latency','Milliseconds (log scale); lower is better',True)
    fig.savefig(args.output/'native-healthy.svg');plt.close(fig)
    fig,axes=plt.subplots(1,2,figsize=(9.6,3.1),layout='constrained')
    bars(axes[0],systems,lambda s:mixed(s,1,'rate'),'One peer voter unavailable','Operations / second; higher is better')
    bars(axes[1],systems,lambda s:mixed(s,2,'p99'),'Entry voter / leader unavailable','Request p99 milliseconds (log scale)',True)
    fig.savefig(args.output/'native-failures.svg');plt.close(fig)
    systems.append('cowsql')
    def kv(system,key):return [r['operations_per_second'] if key=='rate' else r['latency_ms']['p99']
                              for r in report['sequential_writes'] if r['system']==system]
    fig,axes=plt.subplots(1,2,figsize=(9.6,3.4),layout='constrained')
    bars(axes[0],systems,lambda s:kv(s,'rate'),'Sequential 256-byte writes','Operations / second; higher is better')
    bars(axes[1],systems,lambda s:kv(s,'p99'),'Sequential write p99','Milliseconds (log scale); lower is better',True)
    fig.savefig(args.output/'native-sequential.svg');plt.close(fig)
    print('Rendered three benchmark figures; medians with observed min–max whiskers.')


if __name__=='__main__': main()
