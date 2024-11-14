#!/bin/bash

set -e

project_root="$( cd -- "$(dirname "$0")/../.." >/dev/null 2>&1 ; pwd -P )"
echo "Project root: $project_root"

py_venv_path="$project_root/.venv"
cinnamon_path="$project_root/cinnamon"
llvm_path="$project_root/llvm"
torch_mlir_path="$project_root/torch-mlir"
upmem_path="$project_root/upmem"

reconfigure=0

setup_python_venv=1
checkout_and_build_llvm=1
checkout_and_build_torch_mlir=1
checkout_upmem=1

build_cinnamon_wheel=1

enable_cuda=0
enable_roc=0

# Section for configuring based on legacy environment variables
###############################################################

if [ -n "$LLVM_BUILD_DIR" ]; then
  checkout_and_build_llvm=0
  TORCH_MLIR_CMAKE_OPTIONS="$TORCH_MLIR_CMAKE_OPTIONS -DLLVM_DIR=$LLVM_BUILD_DIR/lib/cmake/llvm"
  CINNAMON_CMAKE_OPTIONS="$CINNAMON_CMAKE_OPTIONS -DLLVM_DIR=$LLVM_BUILD_DIR/lib/cmake/llvm"

  echo "Using environment variable LLVM_BUILD_DIR, project is reconfigured automatically, any warnings from this script regarding llvm config can be ignored"
fi

if [ -n "$TORCH_MLIR_INSTALL_DIR" ]; then
  checkout_and_build_torch_mlir=0
  CINNAMON_CMAKE_OPTIONS="$CINNAMON_CMAKE_OPTIONS -DTORCH_MLIR_DIR=$TORCH_MLIR_INSTALL_DIR"

  echo "Using environment variable TORCH_MLIR_INSTALL_DIR, project is reconfigured automatically, any warnings from this script regarding torch-mlir config can be ignored"
fi

if [ -n "$UPMEM_HOME" ]; then
  checkout_upmem=0
  CINNAMON_CMAKE_OPTIONS="$CINNAMON_CMAKE_OPTIONS -DUPMEM_DIR=$UPMEM_HOME"

  echo "Using environment variable UPMEM_HOME, project is reconfigured automatically, any warnings from this script regarding upmem config can be ignored"
fi

###############################################################

if echo "$@" | grep -q "reconfigure"; then
  reconfigure=1
fi

if echo "$@" | grep -q "no-python-venv"; then
  setup_python_venv=0
fi

if echo "$@" | grep -q "no-llvm"; then
  checkout_and_build_llvm=0
fi

if echo "$@" | grep -q "no-torch-mlir"; then
  checkout_and_build_torch_mlir=0
fi

if echo "$@" | grep -q "no-upmem"; then
  checkout_upmem=0
fi

if echo "$@" | grep -q "no-cinnamon-wheel"; then
  build_cinnamon_wheel=0
fi

if echo "$@" | grep -q "enable-cuda"; then
  enable_cuda=1
fi

if echo "$@" | grep -q "enable-roc"; then
  enable_roc=1
fi

if [[ $setup_python_venv -eq 1 ]]; then
  reconfigure_python_venv=0
  if [ ! -d "$py_venv_path" ]; then
    python3 -m venv "$py_venv_path"
    source "$py_venv_path/bin/activate"
    reconfigure_python_venv=1
  else
    source "$py_venv_path/bin/activate"
  fi

  if [ $reconfigure -eq 1 ] || [ $reconfigure_python_venv -eq 1 ]; then
    # https://pytorch.org/get-started/locally/
    if [[ $enable_cuda -eq 1 ]]; then
      torch_source=https://download.pytorch.org/whl/cu124
    elif [[ $enable_roc -eq 1 ]]; then
      torch_source=https://download.pytorch.org/whl/rocm6.1
    else
      torch_source=https://download.pytorch.org/whl/cpu
    fi

    pip install --upgrade pip
    pip install torch torchvision torchaudio --index-url $torch_source
    pip install pybind11
    pip install build
  fi
else
  echo "Skipping Python venv setup"
  echo "Make sure to have a correct Python environment set up"
fi

if [[ $checkout_and_build_llvm -eq 1 ]]; then
  reconfigure_llvm=0
  if [ ! -d "$llvm_path" ]; then
    git clone https://github.com/llvm/llvm-project "$llvm_path"

    cd "$llvm_path"
    git checkout llvmorg-19.1.3

    patch_dir="$project_root/patches/llvm"
    for patch in $(ls $patch_dir); do
      git apply $patch_dir/$patch
    done
    
    reconfigure_llvm=1
  fi

  cd "$llvm_path"

  if [ $reconfigure -eq 1 ] || [ $reconfigure_llvm -eq 1 ]; then
    cmake -S llvm -B build \
      -DLLVM_ENABLE_PROJECTS="mlir;llvm;clang" \
      -DLLVM_TARGETS_TO_BUILD="host" \
      -DLLVM_ENABLE_ASSERTIONS=ON \
      -DMLIR_ENABLE_BINDINGS_PYTHON=ON \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON \
      -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_INCLUDE_BENCHMARKS=OFF \
      -DLLVM_OPTIMIZED_TABLEGEN=ON \
      -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=SPIRV \
      $LLVM_CMAKE_OPTIONS
  fi

  cmake --build build --target all llc opt

  export PATH=$llvm_path/build/bin:$PATH
else
  echo "Skipping LLVM checkout and build"
  echo "The following steps will need LLVM_DIR and MLIR_DIR to be set in their respective <STEP>_CMAKE_OPTIONS"
fi

if [[ $checkout_and_build_torch_mlir -eq 1 ]]; then
  reconfigure_torch_mlir=0
  if [ ! -d "$torch_mlir_path" ]; then
    git clone https://github.com/llvm/torch-mlir "$torch_mlir_path"

    cd "$torch_mlir_path"
    git checkout 98e08023bbf71e00ab81e980eac9f7c96f1f24b4

    reconfigure_torch_mlir=1
  fi

  cd "$torch_mlir_path"

  if [ $reconfigure -eq 1 ] || [ $reconfigure_torch_mlir -eq 1 ]; then
    dependency_paths=""

    if [[ $checkout_and_build_llvm -eq 1 ]]; then
      dependency_paths="$dependency_paths -DLLVM_DIR=$llvm_path/build/lib/cmake/llvm"
      dependency_paths="$dependency_paths -DMLIR_DIR=$llvm_path/build/lib/cmake/mlir"
    fi
    
    cmake -S . -B build \
      $dependency_paths \
      -DCMAKE_BUILD_TYPE=Release \
      -DTORCH_MLIR_OUT_OF_TREE_BUILD=ON \
      -DTORCH_MLIR_ENABLE_STABLEHLO=OFF \
      $TORCH_MLIR_CMAKE_OPTIONS
  fi

  cmake --build build --target all TorchMLIRPythonModules
  cmake --install build --prefix install

  if [[ $setup_python_venv -eq 1 ]]; then
    python_package_dir=build/tools/torch-mlir/python_packages/torch_mlir
    python_package_rel_build_dir=../../../python_packages/torch_mlir
    mkdir -p $(dirname $python_package_dir)
    ln -s "$python_package_rel_build_dir" "$python_package_dir" 2> /dev/null || true
    TORCH_MLIR_CMAKE_ALREADY_BUILT=1 TORCH_MLIR_CMAKE_BUILD_DIR=build python setup.py build install
  fi

else
  echo "Skipping Torch-MLIR checkout and build"
  echo "The following steps will need TORCH_MLIR_DIR to be set in their respective <STEP>_CMAKE_OPTIONS"
fi

if [[ $checkout_upmem -eq 1 ]]; then
  if [ ! -d "$upmem_path" ]; then
    upmem_archive="upmem.tar.gz"
    curl http://sdk-releases.upmem.com/2024.1.0/ubuntu_22.04/upmem-2024.1.0-Linux-x86_64.tar.gz --output "$upmem_archive"
    mkdir "$upmem_path"
    tar xf "$upmem_archive" -C "$upmem_path" --strip-components=1
    rm "$upmem_archive"
  fi
else
  echo "Skipping UpMem checkout"
  echo "The following steps will need UPMEM_DIR to be set in their respective <STEP>_CMAKE_OPTIONS"
fi

cd "$cinnamon_path"

if [ ! -d "build" ] || [ $reconfigure -eq 1 ]; then
  ln -s "$project_root/LICENSE" "$cinnamon_path/python/" 2>/dev/null || true

  dependency_paths=""
  
  if [[ $checkout_and_build_llvm -eq 1 ]]; then
    dependency_paths="$dependency_paths -DLLVM_DIR=$llvm_path/build/lib/cmake/llvm"
    dependency_paths="$dependency_paths -DMLIR_DIR=$llvm_path/build/lib/cmake/mlir"
  fi

  if [[ $checkout_and_build_torch_mlir -eq 1 ]]; then
    dependency_paths="$dependency_paths -DTORCH_MLIR_DIR=$torch_mlir_path/install"  
  fi

  if [[ $checkout_upmem -eq 1 ]]; then
    dependency_paths="$dependency_paths -DUPMEM_DIR=$upmem_path"
  fi

  cmake -S . -B "build" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    $dependency_paths \
    -DCINM_BUILD_GPU_SUPPORT=ON \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    $CINNAMON_CMAKE_OPTIONS
fi

cmake --build build --target all

if [[ $setup_python_venv -eq 1 ]] && [[ -n "$llvm_path" ]] && [[ -n "$torch_mlir_path" ]]; then
  site_packages_dir="$(python -c 'from distutils.sysconfig import get_python_lib; print(get_python_lib())')"
  cinnamon_python_package_dir_src="$project_root/cinnamon/python/src/cinnamon"
  cinnamon_python_package_dir_dest="$site_packages_dir/cinnamon"
  cinnamon_python_package_resource_dir="$cinnamon_python_package_dir_dest/_resources"

  cinnamon_python_resources=""

  cinnamon_python_resources="$cinnamon_python_resources $cinnamon_path/build/bin/cinm-opt"
  cinnamon_python_resources="$cinnamon_python_resources $cinnamon_path/build/lib/libMemristorDialectRuntime.so"

  cinnamon_python_resources="$cinnamon_python_resources $torch_mlir_path/build/bin/torch-mlir-opt"

  cinnamon_python_resources="$cinnamon_python_resources $llvm_path/build/bin/mlir-translate"
  cinnamon_python_resources="$cinnamon_python_resources $llvm_path/build/bin/clang"

  if [ ! -d "$cinnamon_python_package_dir_dest" ]; then
      ln -s "$cinnamon_python_package_dir_src" "$cinnamon_python_package_dir_dest"
  fi

  mkdir -p "$cinnamon_python_package_resource_dir" || true

  for resource in $cinnamon_python_resources; do
    ln -s "$resource" "$cinnamon_python_package_resource_dir" 2>/dev/null || true
  done

  if [[ $build_cinnamon_wheel -eq 1 ]]; then
    cd "$cinnamon_path/python"
    python -m build
  fi
fi