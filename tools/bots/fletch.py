#!/usr/bin/python

# Copyright (c) 2014, the Fletch project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

"""
Buildbot steps for fletch testing
"""

import os
import re
import subprocess
import sys

import bot
import bot_utils

utils = bot_utils.GetUtils()

FLETCH_REGEXP = r'fletch-(linux|mac|windows)'
dirname = os.path.dirname
FLETCH_PATH = dirname(dirname(dirname(os.path.abspath(__file__))))

def Config(name, is_buildbot):
  match = re.match(FLETCH_REGEXP, name)
  if not match:
    print('Builder regexp did not match')
    exit(1)
  # We don't really need this, but it is just much easier than doing all the
  # boilerplate outselves
  return bot.BuildInfo('none', 'none', 'release', match.group(1))


def Run(args):
  print "Running: %s" % ' '.join(args)
  sys.stdout.flush()
  bot.RunProcess(args)


def SetupEnvironment(config):
  if config.system != 'windows':
    os.environ['PATH'] = '%s/third_party/clang/%s/bin:%s' % (
        FLETCH_PATH, config.system, os.environ['PATH'])
  if config.system == 'mac':
    mac_library_path = "third_party/clang/mac/lib/clang/3.6.0/lib/darwin"
    os.environ['DYLD_LIBRARY_PATH'] = '%s/%s' % (FLETCH_PATH, mac_library_path)


def KillFletch(config):
  if config.system != 'windows':
    # Kill any lingering dart processes (from fletch_driver).
    subprocess.call("killall dart", shell=True)
    subprocess.call("killall fletch", shell=True)
    subprocess.call("killall fletch-vm", shell=True)


def Steps(config):
  SetupEnvironment(config)
  if config.system == 'mac':
    # gcc on mac is just an alias for clang.
    compiler_variants = ['Clang']
  else:
    compiler_variants = ['', 'Clang']

  mac = config.system == 'mac'

  with open('.debug.log', 'w') as debug_log:

    # This makes us work from whereever we are called, and restores CWD in exit.
    with utils.ChangedWorkingDirectory(FLETCH_PATH):

      with bot.BuildStep('GYP'):
        Run(['ninja', '-v'])

      configurations = []

      for asan_variant in ['', 'Asan']:
        for compiler_variant in compiler_variants:
          for mode in ['Debug', 'Release']:
            for arch in ['IA32', 'X64']:
              build_conf = '%(mode)s%(arch)s%(clang)s%(asan)s' % {
                'mode': mode,
                'arch': arch,
                'clang': compiler_variant,
                'asan': asan_variant,
              }
              configurations.append({
                'build_conf': build_conf,
                'build_dir': 'out/%s' % build_conf,
                'clang': bool(compiler_variant),
                'asan': bool(asan_variant),
                'mode': mode.lower(),
                'arch': arch.lower(),
              })

      for configuration in configurations:
        with bot.BuildStep('Build %s' % configuration['build_conf']):
          Run(['ninja', '-v', '-C', configuration['build_dir']])

      for full_run in [True, False]:
        for configuration in configurations:
          if mac and configuration['arch'] == 'x64' and configuration['asan']:
            # Asan/x64 takes a long time on mac.
            continue

          full_run_configurations = ['DebugIA32', 'DebugIA32ClangAsan']
          if full_run and (
             configuration['build_conf'] not in full_run_configurations):
            # We only do full runs on DebugIA32 and DebugIA32ClangAsan for now.
            # full_run = compile to snapshot &
            #            run shapshot &
            #            run shapshot with `-Xunfold-program`
            continue

          RunTests(
            configuration['build_conf'],
            configuration['mode'],
            configuration['arch'],
            config,
            clang=configuration['clang'],
            asan=configuration['asan'],
            full_run=full_run,
            build_dir=configuration['build_dir'],
            debug_log=debug_log)

  AnalyzeLog()

def AnalyzeLog():
  # pkg/fletchc/lib/src/driver/driver_main.dart will (to .debug.log) print
  # "1234: Crash (..." when an exception is thrown after shutting down a
  # client.  In this case, there's no obvious place to report the exception, so
  # the build bot must look for these crashes.
  pattern=re.compile(r"^[0-9]+: Crash \(")
  with open('.debug.log') as debug_log:
    undiagnosed_crashes = False
    for line in debug_log:
      if pattern.match(line):
        undiagnosed_crashes = True
        # For information about build bot annotations below, see
        # https://chromium.googlesource.com/chromium/tools/build/+/c63ec51491a8e47b724b5206a76f8b5e137ff1e7/scripts/master/chromium_step.py#472
        print '@@@STEP_LOG_LINE@undiagnosed_crashes@%s@@@' % line.rstrip()
    if undiagnosed_crashes:
      print '@@@STEP_LOG_END@undiagnosed_crashes@@@'
      print '@@@STEP_WARNINGS@@@'
      sys.stdout.flush()


def RunTests(name, mode, arch, config, clang=True, asan=False,
             full_run=False, build_dir=None, debug_log=None):
  step_name = '%s%s' % (name, '-full' if full_run else '')
  with bot.BuildStep('Test %s' % step_name, swallow_error=True):
    args = ['python', 'tools/test.py', '-m%s' % mode, '-a%s' % arch,
            '--time', '--report', '-pbuildbot',
            '--step_name=test_%s' % step_name,
            '--host-checked']
    if full_run:
      # We let package:fletchc/fletchc.dart compile tests to snapshots.
      # Afterwards we run the snapshot with
      #  - normal fletch VM
      #  - fletch VM with -Xunfold-program enabled
      args.extend(['-cfletchc', '-rfletchvm'])

    if asan:
      args.append('--asan')

    if clang:
      args.append('--clang')

    KillFletch(config)

    persistent = subprocess.Popen(
      ['%s/dart' % build_dir,
       '-c',
       '-p',
       './package/',
       'package:fletchc/src/driver/driver_main.dart',
       './.fletch'],
      stdout=debug_log,
      stderr=subprocess.STDOUT,
      close_fds=True)

    try:
      Run(args)
      persistent.terminate()
      persistent.wait()
    finally:
      KillFletch(config)


if __name__ == '__main__':
  bot.RunBot(Config, Steps, build_step=None)
