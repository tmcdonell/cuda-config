cuda-helper
===========

[![Travis build status](https://img.shields.io/travis/tmcdonell/cuda-helper/master.svg?label=linux)](https://travis-ci.org/tmcdonell/cuda-helper)
[![Stackage LTS](https://stackage.org/package/cuda-helper/badge/lts)](https://stackage.org/lts/package/cuda-helper)
[![Stackage Nightly](https://stackage.org/package/cuda-helper/badge/nightly)](https://stackage.org/nightly/package/cuda-helper)
[![Hackage](https://img.shields.io/hackage/v/cuda-helper.svg)](https://hackage.haskell.org/package/cuda-helper)

Determine the installation location of CUDA and generate appropriate
configuration options for Cabal.

This will look for your CUDA installation in the standard places, and if the
`nvcc` compiler is found in your `PATH`, relative to that.

Instructions for installing the CUDA development kit can be found here:

  <http://developer.nvidia.com/object/cuda.html>

