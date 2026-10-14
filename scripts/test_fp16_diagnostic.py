"""Numerical diagnostic helper tests; requires the existing model-export environment."""

import unittest

import numpy as np

from export_models import compare, ranking_diagnostics


class FP16DiagnosticTests(unittest.TestCase):
    def test_diagnostic_measures_error_without_changing_default_gate(self):
        reference = np.ones((1, 768), dtype=np.float32)
        candidate = reference.copy()
        candidate[0, 0] += 0.03
        with self.assertRaises(ValueError):
            compare(reference, candidate, "strict", 1e-3, 0.999)
        measured = compare(reference, candidate, "diagnostic", 1e-3, 0.999, enforce=False)
        self.assertGreater(measured["maxAbs"], 1e-3)
        self.assertGreater(measured["cosine"], 0.999)
        candidate[0, 0] = np.nan
        with self.assertRaises(ValueError):
            compare(reference, candidate, "nonfinite", 1e-3, 0.999, enforce=False)

    def test_ranking_detects_changes_and_keeps_stable_ties(self):
        reference = np.array([[0.8, 0.7, 0.6, 0.5], [0.5, 0.5, 0.2, 0.1]])
        candidate = np.array([[0.7, 0.8, 0.4, 0.6], [0.5, 0.5, 0.2, 0.1]])
        rows = ranking_diagnostics(reference, candidate, ["changed", "ties"], ["a", "b", "c", "d"])
        self.assertTrue(rows[0]["top1Changed"])
        self.assertEqual(rows[0]["top3Overlap"], 2)
        self.assertAlmostEqual(rows[0]["referenceTop1Margin"], 0.1)
        self.assertFalse(rows[1]["top1Changed"])
        self.assertEqual(rows[1]["candidateOrder"], ["a", "b", "c", "d"])
        self.assertEqual(rows[1]["referenceTop1Margin"], 0)

    def test_ranking_rejects_invalid_shapes_and_nonfinite_scores(self):
        with self.assertRaises(ValueError):
            ranking_diagnostics(np.ones((1, 2)), np.ones((1, 3)), ["q"], ["a", "b"])
        with self.assertRaises(ValueError):
            ranking_diagnostics(np.array([[np.inf, 0]]), np.ones((1, 2)), ["q"], ["a", "b"])


if __name__ == "__main__":
    unittest.main()
