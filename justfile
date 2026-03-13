shebang := if os() == 'windows' {
  'bash.exe'
} else {
  '/usr/bin/env bash'
}

export BUILD_CIBUILDWHEEL := "0"
export BUILD_EDITABLE := "0"
export BUILD_DISABLE := "0"

export project_name := "stsci.imagestats"
export project_dir := justfile_directory()
export dist_dir := f"{{project_dir}}/dist"
export test_jail := f"{{project_dir}}/.test_jail"

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
    {{build_pip_cmd}} install --upgrade pip setuptools
    [[ -d {{test_venv_dir}} ]] || python -m venv {{test_venv_dir}}
    {{test_pip_cmd}} install --upgrade pip setuptools

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
    #!{{shebang}}
    set -euxo pipefail

    if ([[ "{{BUILD_DISABLE}}" == "1" ]] || [[ "{{BUILD_EDITABLE}}" == "1" ]]); then
        :
    else
        if [[ "{{BUILD_CIBUILDWHEEL}}" == "1" ]]; then
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
    fi

build-clean:
    if [[ "{{BUILD_DISABLE}}" == "0" ]]; then \
        rm -rf "$dist_dir"; \
        rm -rf "$project_dir"/*.egg-info; \
        rm -rf "$project_dir"/build; \
    fi

guess-wheel-triple:
    #!{{shebang}}
    set -euxo pipefail
    guess_wheel_triple() {
        local output=""
        local plat_real=$(uname -s)
        local arch_real=$(uname -m)
        local arch="$arch_real"
        local plat="$plat_real"
        case "$plat_real" in
            Linux)
                plat=linux
                ;;
            Darwin)
                plat=macosx
                ;;
            Win*|MINGW*|CYGWIN*)
                plat=win
                ;;
        esac

        arch="$arch_real"
        case "$arch_real" in
            i*86)
                arch=32
                ;;
        esac

        case "$plat" in
            linux|macosx)
                output="*$plat*_*$arch"
                ;;
            win)
                if [[ "$arch" == "x86_64" ]]; then
                    plat=amd64
                    output="*$plat_$arch"
                elif [[ "$arch" == "32" ]]; then
                    output="*$plat$arch"
                fi
                ;;
        esac
        echo "$output"
    }
    guess_wheel_triple


test-deps:
    if [[ "{{BUILD_EDITABLE}}" == "1" ]]; then \
        {{test_pip_cmd}} install -e ${project_dir}[test]; \
    else \
        guess=$(just -q guess-wheel-triple); \
        echo "GUESS: $guess"; \
        fn=$(find {{dist_dir}} -name ''$guess.whl'' || echo {{dist_dir}}/'*.whl'); \
        {{test_pip_cmd}} install --force-reinstall "$fn"[test]; \
    fi

[positional-arguments]
test +TARGET='x': build test-deps
    #!{{shebang}}
    set -euxo pipefail

    mkdir -p "$test_jail"
    cd "$test_jail"
    export HOME="$test_jail"

    site_packages=$({{test_python_cmd}} -c 'import site; print(site.getsitepackages()[0])')
    if [[ "{{BUILD_EDITABLE}}" == "1" ]]; then
        install_dir="${project_dir}"/src
    else
        install_dir="${site_packages}"/stsci/imagestats
    fi

    args=(
        "--pyargs ${project_name}"
        "--basetemp=${HOME}/basetemp"
        "--junitxml=${project_dir}/result.xml"
    )
    for target in {{TARGET}}; do
        if [[ "$target" == "x" ]]; then
            break;
        fi

        if [[ "$target" == "cov" ]]; then
            args+=(
                "--cov=${install_dir}"
                "--cov-config=${project_dir}/pyproject.toml"
                "--cov-report=xml:${project_dir}/coverage.xml"
            )
        fi

        just ${target}-deps
    done

    {{test_pytest_cmd}} ${args[@]} ${install_dir}

test-clean:
    rm -f coverage.xml
    rm -f result.xml
    rm -rf "$test_jail"
