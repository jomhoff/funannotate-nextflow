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

The supplied Conda environment pins TransDecoder 5.7.1 because PASA 2.5.3 calls
the legacy `TransDecoder.LongOrfs` and `TransDecoder.Predict` executables
directly. Verify them after creating or updating the environment:

```bash
command -v TransDecoder.LongOrfs
command -v TransDecoder.Predict
```

GeneMark, InterProScan, and the Funannotate databases are deliberately passed as
host paths because they are large and/or cannot be redistributed in a portable
pipeline image.

## RNA evidence input

Supply exactly one of `--reads` or `--trinity`.

### Paired RNA-seq reads

Create a tab-separated reads file with one row per paired RNA-seq library:

```text
sample  left  right
heart   /data/heart_R1.fastq.gz   /data/heart_R2.fastq.gz
kidney  /data/kidney_R1.fastq.gz  /data/kidney_R2.fastq.gz
```

The header is optional. Paths may be absolute or relative to the launch
directory. The sample column is descriptive; all libraries are supplied to one
Funannotate training run in file order.

### Trinity assemblies

Use `--trinity` with either one assembled transcript FASTA or a quoted glob that
matches multiple tissue assemblies. The pipeline stages and concatenates all
matching assemblies before passing one combined FASTA to `funannotate train
--trinity`. During concatenation, every transcript identifier receives a unique
source and record prefix. This prevents the repeated `TRINITY_DN...` identifiers
produced by independent tissue assemblies from violating PASA's unique-accession
constraint. Because assembled transcripts do not retain the raw library layout,
`--stranded` is not used in this mode.

## Run

With paired reads:

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

With preassembled Trinity transcriptomes:

```bash
nextflow run main.nf -profile slurm \
  --genome /data/pantherophis.softmasked.fasta \
  --trinity '/home/jhoffman1/mendel-nas1/pantherophis/transcriptomes/ratsnake_transcriptome_assemblies/*.trinity.fasta' \
  --species 'Pantherophis guttatus' \
  --funannotate_db /mendel-nas1/jhoffman1/fasciatus_genome/funannotate/funannotate_db \
  --genemark_path /home/jhoffman1/mendel-nas1/fasciatus_genome/funannotate/gmes_linux_64_4 \
  --iprscan_path /home/jhoffman1/mendel-nas1/fasciatus_genome/funannotate/my_interproscan/interproscan-5.71-102.0/interproscan.sh \
  --outdir pantherophis_results \
  -resume
```

Keep the Trinity glob quoted so Nextflow, rather than the shell, resolves all
matching files as a single pipeline parameter.

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
