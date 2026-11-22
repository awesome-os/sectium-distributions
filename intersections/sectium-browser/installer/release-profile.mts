/**
 * @file intersections/sectium-browser/installer/release-profile.mts
 * @description Compact static release profile generator, H.264/AAC codec configuration,
 * and multi-OS release matrix for Sectium Browser (`win-x64`, `linux-x64`, `macos-arm64`).
 *
 * Closes Gates 2, 3, & 4:
 *   - Gate 2: Compact Static Release Profile (`is_component_build = false`, ThinLTO, zero symbols)
 *   - Gate 3: H.264/AAC Codec Configuration (`proprietary_codecs = true`, `ffmpeg_branding = "Chrome"`, opt-outable)
 *   - Gate 4: Multi-OS Build Matrix (`win-x64`, `linux-x64`, `macos-arm64` + `< 1 s` Zig companion binaries)
 */

export type SectiumReleaseTarget = 'win-x64' | 'linux-x64' | 'macos-arm64';

export interface StaticReleaseGnOptions {
  /**
   * Enable proprietary H.264/AAC media codecs (`proprietary_codecs = true`, `ffmpeg_branding = "Chrome"`).
   * Set to `false` for pure royalty-free Chromium builds (`ffmpeg_branding = "Chromium"`).
   * @default true
   */
  readonly proprietaryCodecs?: boolean;
  /**
   * Enable Profile-Guided Optimization (`chrome_pgo_phase = 2`).
   * @default false
   */
  readonly pgo?: boolean;
}

export interface CodecProfile {
  readonly proprietaryCodecs: boolean;
  readonly ffmpegBranding: 'Chrome' | 'Chromium';
  readonly mediaUseFfmpeg: true;
  readonly videoCodecs: readonly string[];
  readonly audioCodecs: readonly string[];
}

export interface CompanionBinarySpec {
  readonly name: 'sectium-es' | 'sectium-jvm' | 'sectium_cp';
  readonly binaryFileName: string;
  readonly compiler: 'zig-cc';
  readonly zigTarget: string;
  /** Strict `< 1 s` (1000 ms) native cross-compile budget via hermetic Zig Clang. */
  readonly compileBudgetMs: number;
  readonly role: string;
}

export interface FootprintBudget {
  /** Baseline legacy component-build DLL payload size (~1.46 GB). */
  readonly legacyComponentBytes: number;
  /** Target compressed static release archive size in bytes. */
  readonly targetCompressedBytes: number;
  /** Hard upper-bound compressed static release archive size in bytes. */
  readonly maxCompressedBytes: number;
  /** Hard upper-bound uncompressed static binary payload size in bytes. */
  readonly maxUncompressedBytes: number;
  readonly compressionFormat: 'zstd' | 'zip' | 'dmg-lzma';
}

export interface SectiumReleaseMatrixEntry {
  readonly target: SectiumReleaseTarget;
  readonly targetOs: 'win' | 'linux' | 'mac';
  readonly targetCpu: 'x64' | 'arm64';
  readonly archiveFormat: 'zip' | 'tar.zst' | 'dmg';
  readonly browserBinaryName: string;
  readonly targetBinaryNames: readonly string[];
  readonly companionBinaries: readonly CompanionBinarySpec[];
  readonly footprintBudget: FootprintBudget;
  readonly codecProfile: CodecProfile;
  readonly gnArgs: string;
}

export interface SectiumReleaseMatrix {
  readonly version: string;
  readonly targets: readonly SectiumReleaseTarget[];
  readonly entries: readonly SectiumReleaseMatrixEntry[];
  readonly byTarget: Readonly<Record<SectiumReleaseTarget, SectiumReleaseMatrixEntry>>;
}

export const SECTIUM_RELEASE_VERSION = '160.0.8177.0';

export const SECTIUM_RELEASE_TARGETS: readonly SectiumReleaseTarget[] = [
  'win-x64',
  'linux-x64',
  'macos-arm64',
] as const;

const LEGACY_COMPONENT_BUILD_BYTES = 1_460_000_000; // 1.46 GB component DLL baseline

interface TargetPlatformDescriptor {
  readonly targetOs: 'win' | 'linux' | 'mac';
  readonly targetCpu: 'x64' | 'arm64';
  readonly zigTarget: string;
  readonly exeSuffix: '.exe' | '';
  readonly archiveFormat: 'zip' | 'tar.zst' | 'dmg';
  readonly browserBinaryName: string;
  readonly extraGnLines: readonly string[];
  readonly footprintBudget: FootprintBudget;
}

const TARGET_DESCRIPTORS: Readonly<Record<SectiumReleaseTarget, TargetPlatformDescriptor>> = {
  'win-x64': {
    targetOs: 'win',
    targetCpu: 'x64',
    zigTarget: 'x86_64-windows-gnu',
    exeSuffix: '.exe',
    archiveFormat: 'zip',
    browserBinaryName: 'sectium.exe',
    extraGnLines: [
      'is_clang = true',
      'dcheck_always_on = false',
      'blink_symbol_level = 0',
      'v8_symbol_level = 0',
    ],
    footprintBudget: {
      legacyComponentBytes: LEGACY_COMPONENT_BUILD_BYTES,
      targetCompressedBytes: 95 * 1024 * 1024,
      maxCompressedBytes: 120 * 1024 * 1024,
      maxUncompressedBytes: 310 * 1024 * 1024,
      compressionFormat: 'zip',
    },
  },
  'linux-x64': {
    targetOs: 'linux',
    targetCpu: 'x64',
    zigTarget: 'x86_64-linux-gnu',
    exeSuffix: '',
    archiveFormat: 'tar.zst',
    browserBinaryName: 'sectium',
    extraGnLines: [
      'is_clang = true',
      'dcheck_always_on = false',
      'blink_symbol_level = 0',
      'v8_symbol_level = 0',
      'use_sysroot = true',
      'enable_stripping = true',
      'ozone_platform_wayland = true',
      'ozone_platform_x11 = true',
    ],
    footprintBudget: {
      legacyComponentBytes: LEGACY_COMPONENT_BUILD_BYTES,
      targetCompressedBytes: 88 * 1024 * 1024,
      maxCompressedBytes: 115 * 1024 * 1024,
      maxUncompressedBytes: 295 * 1024 * 1024,
      compressionFormat: 'zstd',
    },
  },
  'macos-arm64': {
    targetOs: 'mac',
    targetCpu: 'arm64',
    zigTarget: 'aarch64-macos',
    exeSuffix: '',
    archiveFormat: 'dmg',
    browserBinaryName: 'Sectium.app/Contents/MacOS/Sectium',
    extraGnLines: [
      'is_clang = true',
      'dcheck_always_on = false',
      'blink_symbol_level = 0',
      'v8_symbol_level = 0',
      'enable_stripping = true',
      'mac_deployment_target = "13.0"',
    ],
    footprintBudget: {
      legacyComponentBytes: LEGACY_COMPONENT_BUILD_BYTES,
      targetCompressedBytes: 90 * 1024 * 1024,
      maxCompressedBytes: 118 * 1024 * 1024,
      maxUncompressedBytes: 300 * 1024 * 1024,
      compressionFormat: 'dmg-lzma',
    },
  },
};

function assertSupportedTarget(target: SectiumReleaseTarget): TargetPlatformDescriptor {
  const descriptor = TARGET_DESCRIPTORS[target];
  if (!descriptor) {
    throw new RangeError(
      `Unsupported Sectium release target: ${String(target)}. Expected one of: ${SECTIUM_RELEASE_TARGETS.join(', ')}`,
    );
  }
  return descriptor;
}

function buildCodecProfile(proprietaryCodecs: boolean): CodecProfile {
  if (proprietaryCodecs) {
    return {
      proprietaryCodecs: true,
      ffmpegBranding: 'Chrome',
      mediaUseFfmpeg: true,
      videoCodecs: ['AV1', 'VP9', 'VP8', 'H.264/AVC', 'HEVC'],
      audioCodecs: ['Opus', 'Vorbis', 'FLAC', 'AAC', 'MP3'],
    };
  }
  return {
    proprietaryCodecs: false,
    ffmpegBranding: 'Chromium',
    mediaUseFfmpeg: true,
    videoCodecs: ['AV1', 'VP9', 'VP8', 'Theora'],
    audioCodecs: ['Opus', 'Vorbis', 'FLAC'],
  };
}

function buildCompanionBinaries(descriptor: TargetPlatformDescriptor): readonly CompanionBinarySpec[] {
  const suffix = descriptor.exeSuffix;
  return [
    {
      name: 'sectium-es',
      binaryFileName: `sectium-es${suffix}`,
      compiler: 'zig-cc',
      zigTarget: descriptor.zigTarget,
      compileBudgetMs: 650,
      role: 'Native ECMAScript/StealifyLang companion runtime binary',
    },
    {
      name: 'sectium-jvm',
      binaryFileName: `sectium-jvm${suffix}`,
      compiler: 'zig-cc',
      zigTarget: descriptor.zigTarget,
      compileBudgetMs: 800,
      role: 'Native JVM bridge & bytecode accelerator companion binary',
    },
    {
      name: 'sectium_cp',
      binaryFileName: `sectium_cp${suffix}`,
      compiler: 'zig-cc',
      zigTarget: descriptor.zigTarget,
      compileBudgetMs: 450,
      role: 'Zero-copy control-plane & CAS payload helper binary',
    },
  ];
}

/**
 * Generates a clean production `args.gn` configuration for a compact static Sectium Browser build.
 *
 * Replaces the 1.46 GB component DLL build with a stripped, ThinLTO, static executable
 * (`is_component_build = false`, `symbol_level = 0`, `use_lld = true`, `use_thin_lto = true`)
 * and configurable H.264/AAC codec support (`proprietary_codecs` + `ffmpeg_branding`).
 */
export function generateStaticReleaseGnArgs(
  target: SectiumReleaseTarget,
  opts?: StaticReleaseGnOptions,
): string {
  const descriptor = assertSupportedTarget(target);
  const proprietaryCodecs = opts?.proprietaryCodecs ?? true;
  const pgo = opts?.pgo ?? false;
  const ffmpegBranding = proprietaryCodecs ? 'Chrome' : 'Chromium';

  const lines: string[] = [
    `# Sectium Browser ${SECTIUM_RELEASE_VERSION} — Compact Static Release Profile (${target})`,
    `# Generated by intersections/sectium-browser/installer/release-profile.mts`,
    '',
    '# Target platform',
    `target_os = "${descriptor.targetOs}"`,
    `target_cpu = "${descriptor.targetCpu}"`,
    '',
    '# Compact static release build (replaces 1.46 GB component DLL layout)',
    'is_debug = false',
    'is_component_build = false',
    'symbol_level = 0',
    'use_lld = true',
    'use_thin_lto = true',
    'enable_nacl = false',
    `chrome_pgo_phase = ${pgo ? '2' : '0'}`,
    '',
    '# Media & codec profile',
    'media_use_ffmpeg = true',
    `proprietary_codecs = ${proprietaryCodecs ? 'true' : 'false'}`,
    `ffmpeg_branding = "${ffmpegBranding}"`,
    '',
    '# Platform-specific release flags',
    ...descriptor.extraGnLines,
    '',
  ];

  return lines.join('\n');
}

/**
 * Builds the complete multi-OS release matrix for `win-x64`, `linux-x64`, and `macos-arm64`,
 * including target binary names, compressed static footprint budgets, codec profiles,
 * `< 1 s` Zig-compiled companion binaries (`sectium-es`, `sectium-jvm`, `sectium_cp`),
 * and generated `args.gn` payloads.
 */
export function buildMultiOsReleaseMatrix(opts?: StaticReleaseGnOptions): SectiumReleaseMatrix {
  const proprietaryCodecs = opts?.proprietaryCodecs ?? true;
  const codecProfile = buildCodecProfile(proprietaryCodecs);

  const entries: SectiumReleaseMatrixEntry[] = SECTIUM_RELEASE_TARGETS.map((target) => {
    const descriptor = TARGET_DESCRIPTORS[target];
    const companionBinaries = buildCompanionBinaries(descriptor);
    const targetBinaryNames = [
      descriptor.browserBinaryName,
      ...companionBinaries.map((bin) => bin.binaryFileName),
    ];

    return {
      target,
      targetOs: descriptor.targetOs,
      targetCpu: descriptor.targetCpu,
      archiveFormat: descriptor.archiveFormat,
      browserBinaryName: descriptor.browserBinaryName,
      targetBinaryNames,
      companionBinaries,
      footprintBudget: descriptor.footprintBudget,
      codecProfile,
      gnArgs: generateStaticReleaseGnArgs(target, opts),
    };
  });

  const byTarget = Object.fromEntries(
    entries.map((entry) => [entry.target, entry]),
  ) as Readonly<Record<SectiumReleaseTarget, SectiumReleaseMatrixEntry>>;

  return {
    version: SECTIUM_RELEASE_VERSION,
    targets: SECTIUM_RELEASE_TARGETS,
    entries,
    byTarget,
  };
}
