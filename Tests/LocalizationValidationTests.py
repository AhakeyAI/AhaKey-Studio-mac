"""Catalog validation regression tests; run with python3 -m unittest discover -s Tests -p '*Tests.py'."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('localization_validator', Path(__file__).resolve().parents[1] / 'scripts/check-localizations.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class LocalizationValidationTests(unittest.TestCase):
    def test_reordering_repetition_and_literal_percent(self):
        self.assertEqual(validator.formats('%@ at %lld%%'), validator.formats('%2$lld%%: %1$@ (%1$@)'))
        self.assertNotEqual(validator.formats('%@ %lld'), validator.formats('%2$@ %1$lld'))
        self.assertEqual(validator.formats('%d %zu %.2f'), [{1: 'd', 2: 'zu', 3: 'f'}])

    def test_conflicting_or_missing_arguments_are_detected(self):
        with self.assertRaises(ValueError):
            validator.formats('%1$lld %1$@')
        self.assertNotEqual(validator.formats('%@ %@'), validator.formats('%@'))
        self.assertNotEqual(validator.formats('%lld'), validator.formats('%d'))

    def test_japanese_other_only_plural_and_reordering(self):
        plural = {'other': {'stringUnit': {'state': 'translated', 'value': '%2$@ に %1$lld フレーム'}}}
        node = {
            'stringUnit': {'state': 'translated', 'value': '%#@frames@'},
            'substitutions': {'frames': {'argNum': 1, 'formatSpecifier': 'lld', 'variations': {'plural': plural}}}
        }
        self.assertEqual(validator.signatures_for(node), [{1: 'lld', 2: '@'}])
        node['substitutions']['frames']['variations']['plural']['other']['stringUnit']['state'] = 'needs_review'
        with self.assertRaises(ValueError):
            validator.signatures_for(node)

    def test_other_variant_is_required(self):
        with self.assertRaises(ValueError):
            validator.signatures_for({'variations': {'plural': {'one': {'stringUnit': {'state': 'translated', 'value': '%lld frame'}}}}})


if __name__ == '__main__':
    unittest.main()
