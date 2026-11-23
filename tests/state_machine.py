"""Exercise the production shell policy without loading a module or using a router."""

from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "scripts/dynbq-controller.sh").read_text()
CONSTANTS = SOURCE.split("\ntrim_log()", 1)[0]
POLICY = SOURCE.split('            NEW="$CUR"\n', 1)[1].split(
    '            eval S$R="$NEW"', 1
)[0]
PROGRAM = CONSTANTS + '''
R=$1; CUR=$2; PR=$3; CL=$4; HC=$5; HX=$6
PPS=$7; OUT=$8; DF=$9
shift 9
DD=$1; DP=$((PPS * INTERVAL)); NEW=$CUR
''' + POLICY + '\nprintf "%s %s %s %s %s\\n" "$NEW" "$PR" "$CL" "$HC" "$HX"\n'


def initial(queue=128):
    return queue, 0, 0, 0, 0


def step(radio, state, pps=0, outstanding=0, feeder_full=0, drops=0):
    """Run the exact case statement and signal calculation from the controller."""
    result = subprocess.run(
        ["sh", "-s", "--", *map(str, (radio, *state, pps, outstanding, feeder_full, drops))],
        input=PROGRAM, text=True, capture_output=True, check=True,
    )
    return tuple(map(int, result.stdout.split()))


class ControllerPolicy(unittest.TestCase):
    def advance(self, radio, state, samples, **signals):
        for _ in range(samples):
            state = step(radio, state, **signals)
        return state

    def test_idle_dwell_and_recovery_for_all_radios(self):
        for radio in range(3):
            with self.subTest(radio=radio):
                state = self.advance(radio, initial(), 7, pps=2000)
                self.assertEqual(state[0], 128)
                state = step(radio, state, pps=2000)
                self.assertEqual(state[0], 64)
                recovery = 12000 if radio == 0 else 4000
                state = self.advance(radio, state, 8, pps=recovery)
                self.assertEqual(state[0], 64)
                state = step(radio, state, pps=recovery)
                self.assertEqual(state[0], 128)

    def test_2ghz_higher_recovery_threshold_and_high_cap(self):
        state = self.advance(0, initial(64), 15, pps=11999)
        self.assertEqual(state[0], 64)
        state = self.advance(0, initial(), 15, pps=50000, outstanding=1000)
        self.assertEqual(state[0], 128)
        self.assertEqual(step(0, initial(192), pps=50000)[0], 128)

    def test_high_entry_hold_and_downshift_on_5_and_6ghz(self):
        for radio in (1, 2):
            with self.subTest(radio=radio):
                # Feeder-full signals alone must not prevent healthy heavy load.
                state = self.advance(radio, initial(), 11, pps=30000,
                                     outstanding=2048, feeder_full=600)
                self.assertEqual(state[0], 128)
                state = step(radio, state, pps=30000, outstanding=2048, feeder_full=600)
                self.assertEqual(state[0], 192)
                state = self.advance(radio, state, 10, pps=20000, outstanding=2048)
                self.assertEqual(state[0], 192)
                state = self.advance(radio, state, 3, pps=10000)
                self.assertEqual(state[0], 192)
                state = step(radio, state, pps=10000)
                self.assertEqual(state[0], 128)
                state = self.advance(radio, initial(192), 3, pps=500)
                self.assertEqual(state[0], 192)
                self.assertEqual(step(radio, state, pps=500)[0], 64)

    def test_real_drop_bypasses_dwell(self):
        for radio, queue in ((0, 128), (1, 128), (1, 192), (2, 128), (2, 192)):
            with self.subTest(radio=radio, queue=queue):
                self.assertEqual(step(radio, initial(queue), pps=40000, drops=1)[0], 64)

    def test_pressure_dwell_and_outstanding_ceiling(self):
        for radio in range(3):
            state = self.advance(radio, initial(), 8, pps=10000, feeder_full=512)
            self.assertEqual(state[0], 128)
            self.assertEqual(step(radio, state, pps=10000, feeder_full=512)[0], 64)
        for radio in (1, 2):
            state = self.advance(radio, initial(), 20, pps=50000, outstanding=2049)
            self.assertEqual(state[0], 128)

    def test_nonconsecutive_signals_reset_dwell(self):
        state = self.advance(1, initial(), 11, pps=40000)
        state = step(1, state, pps=10000)
        self.assertEqual(step(1, state, pps=40000)[0], 128)
        state = self.advance(1, initial(64), 8, pps=4000)
        state = step(1, state, pps=3999)
        self.assertEqual(step(1, state, pps=4000)[0], 64)

    def test_radios_remain_independent(self):
        states = [initial(64) for _ in range(3)]
        for _ in range(25):
            states = [step(radio, state, pps=40000 if radio == 1 else 100)
                      for radio, state in enumerate(states)]
        self.assertEqual([state[0] for state in states], [64, 192, 64])

    def test_unknown_state_recovers_to_mid(self):
        self.assertEqual(step(1, initial(999))[0], 128)

    def test_release_version_matches_controller(self):
        version = (ROOT / "VERSION").read_text().strip()
        self.assertIn(f"\nVERSION={version}\n", SOURCE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
