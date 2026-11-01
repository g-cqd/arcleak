# Grouping findings by similarity (experimental)

`--experimental-embedding-rank` (macOS) groups findings of similar shape in the report. It embeds each flagged line and clusters
by cosine similarity. It only orders the report: it never changes which findings appear, their severity, or the exit code.

By default it uses Apple's on-device `NLContextualEmbedding`, with a deterministic n-gram fallback when the system asset is
missing. That model reads English prose, so it reads source lines poorly and over-clusters. A sentence-embedding model groups
tighter and runs several times faster:

```sh
arcleak analyze Sources --experimental-embedding-rank --embedding-bundle /path/to/Models/MiniLM
export ARCLEAK_EMBEDDING_BUNDLE=/path/to/Models/MiniLM   # the same, without the flag
```

A bundle is a directory with a Core ML model (`.mlpackage` or `.mlmodelc`) and the WordPiece vocabulary it was trained with
(`vocab.txt`, `tokenizer.json` or `config.json`), such as all-MiniLM-L6-v2. BPE and SentencePiece bundles are not supported and
fall back to the default provider.

Choose a **sentence-embedding** model, not a masked-language-model checkpoint. Masked-LM vectors crowd into one narrow cone, so
every pair looks similar; on the same findings, MiniLM spread scores over 36–77%, Apple's model over 2–8%, and CodeBERT over
1–3%.

A model placed next to the binary (`Models/MiniLM`, or `share/arcleak/Models/MiniLM` for a `bin/` and `share/` layout) is found
automatically. The order is `--embedding-bundle`, `ARCLEAK_EMBEDDING_BUNDLE`, next to the executable,
`NLContextualEmbedding`, then the fallback. The status note names the model that ran:

```text
arcleak: experimental embedding-rank grouped 12 finding(s) by flagged-site similarity [provider: bundle:MiniLM]
```

A bundle that fails to load is reported and ignored. On Linux the flag is accepted and ranking is skipped with a note.
