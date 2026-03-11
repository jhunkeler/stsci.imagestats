set shell := ["bash", "-uc"]

export BUILD_CIBUILDWHEEL := "0"
export BUILD_EDITABLE := "0"
export BUILD_DISABLE := "0"

export project_name := "stsci.imagestats"
export project_dir := justfile_directory()
export dist_dir := f"{{project_dir}}/dist"

build_venv_dir := f"{{project_dir}}/.venv/build"
build_python_cmd := f"{{build_venv_dir}}/bin/python"
build_pip_cmd := f"{{build_python_cmd}} -m pip"

test_venv_dir := f"{{project_dir}}/.venv/test"
test_python_cmd := f"{{test_venv_dir}}/bin/python"
test_pip_cmd := f"{{test_python_cmd}} -m pip"
test_pytest_cmd := f"{{test_python_cmd}} -m pytest"

default:
    just -l

clean: venv-clean build-clean test-clean

venv:
    [[ -d {{build_venv_dir}} ]] || python -m venv {{build_venv_dir}}
    {{build_pip_cmd}} install --upgrade pip
    [[ -d {{test_venv_dir}} ]] || python -m venv {{test_venv_dir}}
    {{test_pip_cmd}} install --upgrade pip

venv-clean:
    rm -rf {{build_venv_dir}}
    rm -rf {{test_venv_dir}}

cov-deps:
    {{test_pip_cmd}} install pytest-cov

numpy122-deps:
    {{test_pip_cmd}} install 'numpy==1.22.*'

numpy125-deps:
    {{test_pip_cmd}} install 'numpy==1.25.*'

dev-deps:
    export PIP_EXTRA_INDEX_URL="https://pypi.anaconda.org/scientific-python-nightly-wheels/simple"; \
        {{test_pip_cmd}} install --force --upgrade --pre 'numpy>=0.0.dev0'

build: build-clean venv
    #!/usr/bin/env bash
    set -euxo pipefail

    ([[ "{{BUILD_DISABLE}}" == 1 ]] || [[ "{{BUILD_EDITABLE}}" == "1" ]]) && exit 0

    if [[ "{{BUILD_CIBUILDWHEEL}}" == 1 ]]; then
        if ! docker ps &>/dev/null; then
            echo "Cannot use cibuildwheel because Docker is either not installed, or broken" >&2
            exit 1
        fi
        {{build_pip_cmd}} install cibuildwheel
        v=$({{build_python_cmd}} -V | awk '{ print $2 }')
        v_compact=$(echo "${v%.*}" | tr -d '.')
        manylinux_target=cp${v_compact}-manylinux_{{arch()}}

        {{build_python_cmd}} -m cibuildwheel --output-dir "$dist_dir" --only "${manylinux_target}"
    else
        {{build_pip_cmd}} install build wheel
        {{build_python_cmd}} -m build -w $project_dir
    fi

build-clean:
    [[ "{{BUILD_DISABLE}}" == "1" ]] && exit 0
    rm -rf "{{dist_dir}}"

test-deps:
    if [[ "{{BUILD_EDITABLE}}" == "1" ]]; then \
        {{test_pip_cmd}} install -e ${project_dir}[test]; \
    else \
        fn=$(echo {{dist_dir}}/*.whl); \
        {{test_pip_cmd}} install "$fn"[test]; \
    fi

[positional-arguments]
test +TARGET='x': build test-deps
    #!/usr/bin/env bash
    set -euxo pipefail

    site_packages=$({{test_python_cmd}} -c 'import site; print(site.getsitepackages()[0])')
    if [[ "{{BUILD_EDITABLE}}" == 1 ]]; then
        install_dir="${project_dir}/src"
    else
        install_dir="${site_packages}"/stsci/imagestats
    fi

    args=(
        "--pyargs ${project_name}"
        "--junitxml=result.xml"
    )
    for target in {{TARGET}}; do
        if [[ "$target" == "x" ]]; then
            break;
        fi

        if [[ "$target" == "cov" ]]; then
            args+=(
                "--cov=${install_dir}"
                "--cov-config=${project_dir}/pyproject.toml"
                "--cov-report=xml:coverage.xml"
            )
        fi

        just ${target}-deps || exit $?
    done
    set -x
    {{test_pytest_cmd}} ${args[@]} ${install_dir}

test-clean:
    rm -f coverage.xml
    rm -f result.xml
