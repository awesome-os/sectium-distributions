import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  buildMultiOsReleaseMatrix,
  generateStaticReleaseGnArgs,
  SECTIUM_RELEASE_TARGETS,
  type SectiumReleaseTarget,
} from './release-profile.mts';

function parseGnAssignments(gnArgs: string): Map<string, string> {
  const map = new Map<string, string>();
  for (const rawLine of gnArgs.split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const eqIdx = line.indexOf('=');
    assert.ok(eqIdx > 0, `Invalid GN assignment line: ${line}`);
    const key = line.slice(0, eqIdx).trim();
    const val = line.slice(eqIdx + 1).trim();
    assert.ok(!map.has(key), `Duplicate GN key detected: ${key}`);
    map.set(key, val);
  }
  return map;
}

describe('sectium-browser static release profile & multi-OS matrix', () => {
  const expectedPlatformFlags: Record<
    SectiumReleaseTarget,
    { targetOs: string; targetCpu: string; extraKey: string }
  > = {
    'win-x64': { targetOs: '"win"', targetCpu: '"x64"', extraKey: 'is_clang' },
    'linux-x64': { targetOs: '"linux"', targetCpu: '"x64"', extraKey: 'use_sysroot' },
    'macos-arm64': { targetOs: '"mac"', targetCpu: '"arm64"', extraKey: 'mac_deployment_target' },
  };

  it('emits valid static is_component_build = false GN args for all 3 OS profiles', () => {
    for (const target of SECTIUM_RELEASE_TARGETS) {
      const gnArgs = generateStaticReleaseGnArgs(target);
      const parsed = parseGnAssignments(gnArgs);

      assert.equal(parsed.get('is_debug'), 'false', `${target}: is_debug`);
      assert.equal(parsed.get('is_component_build'), 'false', `${target}: is_component_build`);
      assert.equal(parsed.get('symbol_level'), '0', `${target}: symbol_level`);
      assert.equal(parsed.get('use_lld'), 'true', `${target}: use_lld`);
      assert.equal(parsed.get('use_thin_lto'), 'true', `${target}: use_thin_lto`);
      assert.equal(parsed.get('enable_nacl'), 'false', `${target}: enable_nacl`);
      assert.equal(parsed.get('media_use_ffmpeg'), 'true', `${target}: media_use_ffmpeg`);
      assert.equal(parsed.get('proprietary_codecs'), 'true', `${target}: proprietary_codecs`);
      assert.equal(parsed.get('ffmpeg_branding'), '"Chrome"', `${target}: ffmpeg_branding`);
      assert.equal(parsed.get('chrome_pgo_phase'), '0', `${target}: default pgo phase`);

      const expected = expectedPlatformFlags[target];
      assert.equal(parsed.get('target_os'), expected.targetOs, `${target}: target_os`);
      assert.equal(parsed.get('target_cpu'), expected.targetCpu, `${target}: target_cpu`);
      assert.ok(parsed.has(expected.extraKey), `${target}: missing ${expected.extraKey}`);
    }
  });

  it('toggles proprietary_codecs and ffmpeg_branding cleanly for royalty-free builds', () => {
    for (const target of SECTIUM_RELEASE_TARGETS) {
      const proprietary = parseGnAssignments(
        generateStaticReleaseGnArgs(target, { proprietaryCodecs: true }),
      );
      assert.equal(proprietary.get('proprietary_codecs'), 'true');
      assert.equal(proprietary.get('ffmpeg_branding'), '"Chrome"');

      const royaltyFree = parseGnAssignments(
        generateStaticReleaseGnArgs(target, { proprietaryCodecs: false }),
      );
      assert.equal(royaltyFree.get('proprietary_codecs'), 'false');
      assert.equal(royaltyFree.get('ffmpeg_branding'), '"Chromium"');
      assert.equal(royaltyFree.get('media_use_ffmpeg'), 'true');
    }
  });

  it('toggles PGO phase cleanly via opts.pgo', () => {
    const withPgo = parseGnAssignments(generateStaticReleaseGnArgs('win-x64', { pgo: true }));
    const withoutPgo = parseGnAssignments(generateStaticReleaseGnArgs('win-x64', { pgo: false }));

    assert.equal(withPgo.get('chrome_pgo_phase'), '2');
    assert.equal(withoutPgo.get('chrome_pgo_phase'), '0');
  });

  it('rejects unsupported release targets with a RangeError', () => {
    assert.throws(
      () => generateStaticReleaseGnArgs('solaris-sparc' as SectiumReleaseTarget),
      RangeError,
    );
  });

  it('buildMultiOsReleaseMatrix returns complete win-x64, linux-x64, and macos-arm64 entries', () => {
    const matrix = buildMultiOsReleaseMatrix();

    assert.deepEqual([...matrix.targets], ['win-x64', 'linux-x64', 'macos-arm64']);
    assert.equal(matrix.entries.length, 3);

    const expectedCompanions = ['sectium-es', 'sectium-jvm', 'sectium_cp'];

    for (const target of SECTIUM_RELEASE_TARGETS) {
      const entry = matrix.byTarget[target];
      assert.ok(entry, `Missing matrix entry for ${target}`);
      assert.equal(entry.target, target);

      // Footprint budget must drastically beat the 1.46 GB component DLL baseline
      assert.equal(entry.footprintBudget.legacyComponentBytes, 1_460_000_000);
      assert.ok(
        entry.footprintBudget.targetCompressedBytes < entry.footprintBudget.maxCompressedBytes,
        `${target}: targetCompressedBytes < maxCompressedBytes`,
      );
      assert.ok(
        entry.footprintBudget.maxCompressedBytes < 150 * 1024 * 1024,
        `${target}: compressed static budget should be < 150 MiB`,
      );
      assert.ok(
        entry.footprintBudget.maxUncompressedBytes < entry.footprintBudget.legacyComponentBytes / 3,
        `${target}: uncompressed static budget should be well below 1.46 GB component DLL build`,
      );

      // Default codec profile includes H.264/AAC under Chrome branding
      assert.equal(entry.codecProfile.proprietaryCodecs, true);
      assert.equal(entry.codecProfile.ffmpegBranding, 'Chrome');
      assert.ok(entry.codecProfile.videoCodecs.some((c) => c.includes('H.264')));
      assert.ok(entry.codecProfile.audioCodecs.includes('AAC'));

      // < 1 s Zig-compiled companion binaries
      assert.deepEqual(
        entry.companionBinaries.map((c) => c.name),
        expectedCompanions,
      );
      for (const companion of entry.companionBinaries) {
        assert.equal(companion.compiler, 'zig-cc');
        assert.ok(
          companion.compileBudgetMs > 0 && companion.compileBudgetMs < 1000,
          `${target}/${companion.name}: compileBudgetMs must be < 1000 ms`,
        );
        if (target === 'win-x64') {
          assert.ok(companion.binaryFileName.endsWith('.exe'));
        } else {
          assert.ok(!companion.binaryFileName.endsWith('.exe'));
        }
        assert.ok(entry.targetBinaryNames.includes(companion.binaryFileName));
      }
      assert.ok(entry.targetBinaryNames.includes(entry.browserBinaryName));

      // Embedded GN args match generator output
      assert.equal(entry.gnArgs, generateStaticReleaseGnArgs(target));
    }
  });

  it('buildMultiOsReleaseMatrix supports royalty-free codec opt-out across all targets', () => {
    const matrix = buildMultiOsReleaseMatrix({ proprietaryCodecs: false });
    for (const entry of matrix.entries) {
      assert.equal(entry.codecProfile.proprietaryCodecs, false);
      assert.equal(entry.codecProfile.ffmpegBranding, 'Chromium');
      assert.ok(!entry.codecProfile.videoCodecs.some((c) => c.includes('H.264')));
      assert.ok(!entry.codecProfile.audioCodecs.includes('AAC'));
      assert.match(entry.gnArgs, /proprietary_codecs = false/);
      assert.match(entry.gnArgs, /ffmpeg_branding = "Chromium"/);
    }
  });
});
