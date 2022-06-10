'''
This file contains rules that run the canonical augur pipeline on a set of sequences
and generate a tree and a number of node_jsons

input:
 - builds/{build_name}/strains.txt
 - builds/{build_name}/metadata.tsv
 - builds/{build_name}/{segment}/sequences.fasta

output:
 - builds/{build_name}/{segment}/tree_raw.nwk
 - builds/{build_name}/{segment}/tree.nwk
 - builds/{build_name}/{segment}/branch-lengths.json
 - builds/{build_name}/{segment}/aa-muts.json
 - builds/{build_name}/{segment}/nt-muts.json
 - builds/{build_name}/{segment}/traits.json
'''

build_dir = config.get("build_dir", "builds")

GENES = {
    'ha': ['SigPep', 'HA1', 'HA2'],
    'na': ['NA'],
}

rule mask:
    input:
        sequences = build_dir + "/{build_name}/{segment}/sequences.fasta",
    output:
        sequences = build_dir + "/{build_name}/{segment}/masked.fasta",
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur mask \
            --sequences {input.sequences} \
            --mask-invalid \
            --output {output.sequences}
        """

checkpoint align:
    message:
        """
        Aligning sequences to {input.reference}
        """
    input:
        sequences = build_dir + "/{build_name}/{segment}/masked.fasta",
        reference =  lambda w: config['builds'][w.build_name]['reference'],
        annotation = lambda w: config['builds'][w.build_name]['annotation'],
    output:
        alignment = build_dir + "/{build_name}/{segment}/aligned.fasta",
        translations = directory(build_dir + "/{build_name}/{segment}/nextalign"),
    conda: "../envs/nextstrain.yaml"
    params:
        genes = lambda w: ','.join(GENES[w.segment]),
        outdir =  build_dir + "/{build_name}/{segment}/nextalign",
    threads: 8
    resources:
        mem_mb=16000
    shell:
        """
        nextalign -r {input.reference} \
                  -m {input.annotation} \
                  --genes {params.genes} \
                  --jobs {threads} \
                  -i {input.sequences} \
                  -o {output.alignment} \
                  --output-dir {params.outdir}
        """

def aggregate_translations(wildcards):
    """The alignment rule produces multiple outputs that we cannot easily name prior
    to running the rule. The names of the outputs depend on the segment being
    aligned and Snakemake's `expand` function does not provide a way to lookup
    the gene names per segment. Instead, we use Snakemake's checkpoint
    functionality to determine the names of the output files after alignment
    runs. Downstream rules refer to this function to specify the translations
    for a given segment.

    """
    checkpoint_output = checkpoints.align.get(**wildcards).output.translations
    return expand(build_dir + "/{build_name}/{segment}/nextalign/masked.gene.{gene}.fasta",
                  build_name=wildcards.build_name,
                  segment=wildcards.segment,
                  gene=glob_wildcards(os.path.join(checkpoint_output, "masked.gene.{gene}.fasta")).gene)

rule tree:
    message: "Building tree"
    input:
        alignment = rules.align.output.alignment,
    output:
        tree = build_dir + "/{build_name}/{segment}/tree_raw.nwk"
    conda: "../envs/nextstrain.yaml"
    params:
        tree_builder_args = config["tree"]["tree-builder-args"]
    threads: 8
    resources:
        mem_mb=16000
    shell:
        """
        augur tree \
            --alignment {input.alignment} \
            --tree-builder-args {params.tree_builder_args} \
            --output {output.tree} \
            --nthreads {threads}
        """

rule sanitize_trees:
    input:
        trees = expand("{build_dir}/{{build_name}}/{segment}/tree_raw.nwk",  segment=config['segments'], build_dir=[build_dir]),
    output:
        trees = expand("{build_dir}/{{build_name}}/{segment}/tree_common.nwk",  segment=config['segments'], build_dir=[build_dir]),
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/sanitize_trees.py \
            --trees {input.trees:q} \
            --output {output.trees:q}
        """

def clock_rate(w):
    # these rates are from 12y runs on 2019-10-18
    rate = {
     ('h1n1pdm', 'ha'): 0.00329,
 	 ('h1n1pdm', 'na'): 0.00326,
 	 ('h1n1pdm', 'np'): 0.00221,
 	 ('h1n1pdm', 'pa'): 0.00217,
	 ('h1n1pdm', 'pb1'): 0.00205,
 	 ('h1n1pdm', 'pb2'): 0.00277,
 	 ('h3n2', 'ha'): 0.00382,
 	 ('h3n2', 'na'): 0.00267,
	 ('h3n2', 'np'): 0.00157,
 	 ('h3n2', 'pa'): 0.00178,
 	 ('h3n2', 'pb1'): 0.00139,
 	 ('h3n2', 'pb2'): 0.00218,
 	 ('vic', 'ha'): 0.00145,
 	 ('vic', 'na'): 0.00133,
 	 ('vic', 'np'): 0.00132,
 	 ('vic', 'pa'): 0.00178,
 	 ('vic', 'pb1'): 0.00114,
 	 ('vic', 'pb2'): 0.00106,
 	 ('yam', 'ha'): 0.00176,
 	 ('yam', 'na'): 0.00177,
 	 ('yam', 'np'): 0.00133,
 	 ('yam', 'pa'): 0.00112,
 	 ('yam', 'pb1'): 0.00092,
 	 ('yam', 'pb2'): 0.00113}
    return rate.get((config['builds'][w.build_name]["lineage"], w.segment), 0.001)

def clock_std_dev(w):
    return clock_rate(w)/5

rule refine:
    message:
        """
        Refining tree
          - estimate timetree
          - use {params.coalescent} coalescent timescale
          - estimate {params.date_inference} node dates
          - filter tips more than {params.clock_filter_iqd} IQDs from clock expectation
        """
    input:
        tree = build_dir + "/{build_name}/{segment}/tree_common.nwk",
        alignment = build_dir + "/{build_name}/{segment}/aligned.fasta",
        metadata = build_dir + "/{build_name}/metadata.tsv"
    output:
        tree = build_dir + "/{build_name}/{segment}/tree.nwk",
        node_data = build_dir + "/{build_name}/{segment}/branch-lengths.json"
    params:
        coalescent = "const",
        date_inference = "marginal",
        clock_filter_iqd = 4,
        clock_rate = clock_rate,
        clock_std_dev = clock_std_dev
    conda: "../envs/nextstrain.yaml"
    resources:
        mem_mb=16000
    shell:
        """
        augur refine \
            --tree {input.tree} \
            --alignment {input.alignment} \
            --metadata {input.metadata} \
            --output-tree {output.tree} \
            --output-node-data {output.node_data} \
            --timetree \
            --no-covariance \
            --clock-rate {params.clock_rate} \
            --clock-std-dev {params.clock_std_dev} \
            --coalescent {params.coalescent} \
            --date-confidence \
            --date-inference {params.date_inference} \
            --clock-filter-iqd {params.clock_filter_iqd}
        """

rule ancestral:
    message: "Reconstructing ancestral sequences and mutations"
    input:
        tree = rules.refine.output.tree,
        alignment = rules.align.output.alignment,
    output:
        node_data = build_dir + "/{build_name}/{segment}/nt-muts.json"
    params:
        inference = "joint"
    conda: "../envs/nextstrain.yaml"
    resources:
        mem_mb=4000
    shell:
        """
        augur ancestral \
            --tree {input.tree} \
            --alignment {input.alignment} \
            --output-node-data {output.node_data} \
            --inference {params.inference}
        """

rule translate:
    message: "Translating amino acid sequences"
    input:
        translations = aggregate_translations,
        tree = rules.refine.output.tree,
        reference =  lambda w: f"{config['builds'][w.build_name]['reference']}",
        annotation = lambda w: f"{config['builds'][w.build_name]['annotation']}",
    output:
        node_data = build_dir + "/{build_name}/{segment}/aa_muts.json",
        translations_done = build_dir + "/{build_name}/{segment}/translations.done"
    params:
        genes = lambda w: GENES[w.segment]
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/translations_aamuts.py \
            --tree {input.tree} \
            --annotation {input.annotation} \
            --reference {input.reference} \
            --translations {input.translations:q} \
            --genes {params.genes} \
            --output {output.node_data} 2>&1 | tee {log} && touch {output.translations_done}
        """

rule traits:
    message:
        """
        Inferring ancestral traits for {params.columns!s}
        """
    input:
        tree = rules.refine.output.tree,
        metadata = build_dir + "/{build_name}/metadata.tsv"
    output:
        node_data = build_dir + "/{build_name}/{segment}/traits.json",
    params:
        columns = "region"
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur traits \
            --tree {input.tree} \
            --metadata {input.metadata} \
            --output {output.node_data} \
            --columns {params.columns} \
            --confidence
        """

# Determine clades with HA mutations.
rule clades:
    input:
        tree = build_dir + "/{build_name}/ha/tree.nwk",
        nt_muts = build_dir + "/{build_name}/ha/nt-muts.json",
        aa_muts = build_dir + "/{build_name}/ha/aa_muts.json",
        clades = lambda wildcards: config[build_dir + ""][wildcards.build_name]["clades"],
    output:
        node_data = build_dir + "/{build_name}/ha/clades.json",
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur clades \
            --tree {input.tree} \
            --mutations {input.nt_muts} {input.aa_muts} \
            --clades {input.clades} \
            --output {output.node_data}
        """

# Assign clade annotations to non-HA segments from HA.
rule import_clades:
    input:
        tree = build_dir + "/{build_name}/ha/tree.nwk",
        nt_muts = build_dir + "/{build_name}/{segment}/nt-muts.json",
        aa_muts = build_dir + "/{build_name}/{segment}/aa_muts.json",
        clades = build_dir + "/{build_name}/ha/clades.json",
    output:
        node_data = build_dir + "/{build_name}/{segment}/clades.json",
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/import_tip_clades.py \
            --tree {input.tree} \
            --clades {input.clades} \
            --output {output.node_data}
        """

rule tip_frequencies:
    input:
        tree = rules.refine.output.tree,
        metadata = build_dir + "/{build_name}/metadata.tsv",
        weights = "config/frequency_weights_by_region.json"
    params:
        narrow_bandwidth = 2 / 12.0,
        wide_bandwidth = 3 / 12.0,
        proportion_wide = 0.0,
        weight_attribute = "region",
        min_date_arg = lambda w: f"--min-date {config['builds'][w.build_name]['min_date']}" if "min_date" in config["builds"].get(w.build_name, {}) else "",
        max_date = lambda w: config['builds'][w.build_name]['max_date'] if "max_date" in config["builds"].get(w.build_name, {}) else "0D",
        pivot_interval = 2
    output:
        tip_freq = "auspice/{build_name}_{segment}_tip-frequencies.json"
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur frequencies \
            --method kde \
            --tree {input.tree} \
            --metadata {input.metadata} \
            --narrow-bandwidth {params.narrow_bandwidth} \
            --wide-bandwidth {params.wide_bandwidth} \
            --proportion-wide {params.proportion_wide} \
            --weights {input.weights} \
            --weights-attribute {params.weight_attribute} \
            --pivot-interval {params.pivot_interval} \
            {params.min_date_arg} \
            --max-date {params.max_date} \
            --output {output}
        """