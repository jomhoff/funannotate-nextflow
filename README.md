# Funannotate Nextflow pipeline

This DSL2 pipeline turns the workflow in
[`functional_annotation.md`](https://github.com/jomhoff/Genome-Annotation/blob/main/functional_annotation.md)
into a resumable chain:

`train -> predict -> update -> [fix] -> iprscan -> annotate`

`fix` is skipped unless `--corrected_tbl` is supplied. This preserves the manual
review step: inspect the update log/archive, edit the generated NCBI `.tbl`, then
resume with the corrected file.

## Requirements

- Nextflow 23.10 or newer
- Funannotate and its databases
- A separately licensed GeneMark installation
- A local InterProScan installation configured for the compute environment
- Mamba/Conda when using `-profile conda`

GeneMark, InterProScan, and the Funannotate databases are deliberately passed as
host paths because they are large and/or cannot be redistributed in a portable
pipeline image.

## Input

Create a tab-separated reads file with one row per paired RNA-seq library:

```text
sample  left  right
heart   /data/heart_R1.fastq.gz   /data/heart_R2.fastq.gz
kidney  /data/kidney_R1.fastq.gz  /data/kidney_R2.fastq.gz
```

The header is optional. Paths may be absolute or relative to the launch
directory. The sample column is descriptive; all libraries are supplied to one
Funannotate training run in file order.

## Run

```bash
nextflow run main.nf -profile slurm,conda \
  --genome /data/genome.softmasked.fasta \
  --reads reads.tsv \
  --species 'Plestiodon fasciatus' \
  --funannotate_db /db/funannotate \
  --genemark_path /opt/gmes_linux_64_4 \
  --iprscan_path /opt/interproscan/interproscan.sh \
  --outdir results
```

After manually correcting a `.tbl`, resume the cached run:

```bash
nextflow run main.nf -profile slurm,conda -resume \
  [the same parameters as above] \
  --corrected_tbl /data/Plestiodon_fasciatus.corrected.tbl
```

Use `-profile conda` only if you want Nextflow to create the Funannotate
environment. If your cluster already provides a working environment, omit it and
launch Nextflow from that environment. The Slurm profile retains the CPU, memory,
and walltime requests from the original scripts; override any process with a
site-specific config passed through `-c`.

The final complete Funannotate directory is copied to `results/annotation`.
Nextflow also writes execution report, trace, timeline, and DAG files in the
launch directory.

## Notes

- `stageInMode = 'copy'` is required because Funannotate mutates its project
  directory at each stage. It prevents a later task from changing a cached
  upstream result through a symlink.
- InterProScan's own Slurm configuration remains external to this workflow. The
  `IPRSCAN` task requests one Slurm allocation and invokes Funannotate in local
  mode inside it.
- Use `-resume` after failures or after providing a corrected table; completed
  stages are recovered from the Nextflow work directory.
