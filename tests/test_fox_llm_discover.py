#!/usr/bin/env python3
"""tests/test_fox_llm_discover.py — fox-llm-discover's tag filter + MoE classifier, offline.

Network calls (ollama.com pages, registry manifests) are replaced with canned values;
what is tested is the decision logic: which tags count as plain sizes, what is MoE,
and which tag wins per model.
"""
import importlib.machinery
import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("fox_llm_discover", str(ROOT / "shared/bin/fox-llm-discover"))
spec = importlib.util.spec_from_loader(loader.name, loader)
d = importlib.util.module_from_spec(spec)
loader.exec_module(d)


class DiscoverTest(unittest.TestCase):
    def fake(self, tags, sizes, arch, family_moe=False):
        d.plain_tags = lambda name: [t for t in tags if d.PLAIN.match(t)]
        d.size_gb = lambda ref: sizes.get(ref.split(":", 1)[1]) if "abliterated" not in ref else None
        d.tag_arch = lambda name, tag: arch.get(tag, "")
        d.family_is_moe = lambda name: family_moe

    def test_plain_tags_only(self):
        for t in ("latest", "30b", "26b-a4b", "e4b", "1.5b", "270m"):
            self.assertTrue(d.PLAIN.match(t), t)
        for t in ("26b-a4b-it-q8_0", "12b-mlx", "20b-cloud", "12b-it-qat", "26b-nvfp4"):
            self.assertFalse(d.PLAIN.match(t), t)

    def test_moe_from_arch_beats_dense_sibling(self):
        # qwen3-coder: "30b" has no -aNb tag, but its arch says MoE.
        self.fake(["30b", "480b-a35b"], {"30b": 18.6, "480b-a35b": 290}, {"30b": "qwen3moe"})
        ref, gb, cls, _ = d.best_fit("qwen3-coder", 24, 9)
        self.assertEqual((ref, cls), ("qwen3-coder:30b", "moe"))

    def test_moe_tag_preferred_over_bigger_dense(self):
        # qwen3.6: dense 27b (17 GB) vs MoE 35b-a3b (22.6 GB) — MoE wins, it's agent speed.
        self.fake(["27b", "35b-a3b"], {"27b": 17.0, "35b-a3b": 22.6}, {"27b": "qwen35", "35b-a3b": "qwen35moe"})
        ref, _, cls, _ = d.best_fit("qwen3.6", 24, 9)
        self.assertEqual((ref, cls), ("qwen3.6:35b-a3b", "moe"))

    def test_family_text_only_for_unfamiliar_arch(self):
        # laguna: arch hides MoE, family page says it → moe.
        self.fake(["latest"], {"latest": 20.3}, {"latest": "laguna"}, family_moe=True)
        self.assertEqual(d.best_fit("laguna-xs-2.1", 24, 9)[2], "moe")
        # granite dense: family page mentions MoE siblings, arch is familiar → not moe.
        self.fake(["8b"], {"8b": 5.0}, {"8b": "granite"}, family_moe=True)
        self.assertEqual(d.best_fit("granite3.1-dense", 24, 9)[2], "small")

    def test_too_big_dropped_and_dense_classes(self):
        self.fake(["70b", "27b", "8b"], {"70b": 42, "27b": 17.7, "8b": 5.2}, {})
        self.assertEqual(d.best_fit("bigdense", 24, 9)[:3], ("bigdense:8b", 5.2, "small"))
        self.fake(["70b"], {"70b": 42}, {})
        self.assertIsNone(d.best_fit("bigdense", 24, 9))
        self.fake(["27b"], {"27b": 17.7}, {"27b": "qwen35"})
        self.assertEqual(d.best_fit("qwen3.8", 24, 9)[2], "slow")


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
