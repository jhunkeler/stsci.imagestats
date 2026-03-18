export BUILD_CIBUILDWHEEL := ""
export BUILD_EDITABLE := ""
export BUILD_DISABLE := ""
export ON_WINDOWS := if os() == "windows" { "ON WINDOWS" } else { "" }
export ON_MACOS := if os() == "macos" { "ON MACOS" } else { "" }

export project_name := "stsci.imagestats"

shebang := if os() == 'windows' {
    shell('cygpath --unix "$1"', require("bash.exe"))
} else {
    require("bash")
}

venv_python_executable := if os() == 'windows' {
    'python.exe'
} else {
    'python'
}

export project_dir := if os() == 'windows' {
    shell('cygpath --unix "$1"', justfile_directory())
} else {
    justfile_directory()
}

export dist_dir := if os() == 'windows' {
    shell('cygpath --unix "$1/dist"', project_dir)
} else {
    f"{{project_dir}}/dist"
}

export test_jail := if os() == 'windows' {
    shell('cygpath --unix "$1/.test_jail"', project_dir)
} else {
    f"{{project_dir}}/.test_jail"
}

build_venv_dir := if os() == 'windows' {
    shell('cygpath --unix "$1"/.venv/build', project_dir)
} else {
    f"{{project_dir}}/.venv/build"
}

build_python_cmd := if os() == 'windows' {
    shell('cygpath --unix "$1/Scripts/$2"', build_venv_dir, venv_python_executable)
} else {
    f"{{build_venv_dir}}/bin/{{venv_python_executable}}"
}

build_pip_cmd := if os() == 'windows' {
    shell('cygpath --unix "$1 -m pip"', build_python_cmd)
} else {
    f"{{build_python_cmd}} -m pip"
}

test_venv_dir := if os() == 'windows' {
    shell('cygpath --unix "$1/.venv/test"', project_dir)
} else {
    f"{{project_dir}}/.venv/test"
}

test_python_cmd := if os() == 'windows' {
    shell('cygpath --unix "$1/Scripts/$2"', test_venv_dir, venv_python_executable)
} else {
    f"{{test_venv_dir}}/bin/{{venv_python_executable}}"
}

test_pip_cmd := if os() == 'windows' {
    shell('cygpath --unix "$1 -m pip"', test_python_cmd)
} else {
    f"{{test_python_cmd}} -m pip"
}

test_pytest_cmd := if os() == 'windows' {
    shell('cygpath --unix "$1 -m pytest"', test_python_cmd)
} else {
    f"{{test_python_cmd}} -m pytest"
}

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

cov-install-deps:
    {{test_pip_cmd}} install pytest-cov

numpy122-install-deps:
    {{test_pip_cmd}} install 'numpy==1.22.*'

numpy125-install-deps:
    {{test_pip_cmd}} install 'numpy==1.25.*'

dev-install-deps:
    export PIP_EXTRA_INDEX_URL="https://pypi.anaconda.org/scientific-python-nightly-wheels/simple"; \
        {{test_pip_cmd}} install --force --upgrade --pre 'numpy>=0.0.dev0'

build: build-clean venv
    #!{{shebang}}
    set -euxo pipefail

    if ([[ "{{BUILD_DISABLE}}" ]] || [[ "{{BUILD_EDITABLE}}" ]]); then
        exit 0
    fi

    if [[ "{{BUILD_CIBUILDWHEEL}}" ]]; then
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
    if [[ -z "{{BUILD_DISABLE}}" ]]; then \
        rm -rf "$dist_dir"; \
        rm -rf "$project_dir"/*.egg-info; \
        rm -rf "$project_dir"/build; \
    fi

guess-wheel-latest +files:
    #!{{shebang}}
    set -euo pipefail
    fmt_arg='-c'
    fmt='%Y %n'
    if [[ "${ON_MACOS}" ]]; then
        fmt_arg='-f'
        fmt='%m %N'
    fi
    stat ${fmt_arg} "${fmt}" {{files}} | sort -rn | head -n 1 | cut -d ' ' -f 2-

guess-wheel-triple:
    #!{{shebang}}
    set -euo pipefail
    guess_wheel_triple() {
        local output=""
        local plat_real="$(uname -s)"
        local arch_real="$(uname -m)"
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

        arch="${arch_real}"
        case "${arch_real}" in
            i*86)
                arch=32
                ;;
        esac

        case "$plat" in
            linux|macosx)
                output="*${plat}*_*${arch}"
                ;;
            win)
                if [[ "$arch" == "x86_64" ]]; then
                    arch=amd64
                    output="*${plat}_${arch}"
                elif [[ "$arch" == "32" ]]; then
                    output="*${plat}${arch}"
                fi
                ;;
        esac
        echo "$output"
    }
    guess_wheel_triple



test-install-deps:
    #!{{shebang}}
    set -euo pipefail
    if [[ "{{BUILD_EDITABLE}}" ]]; then
        {{test_pip_cmd}} install -e ${project_dir}[test]
    else
        triple=$(just -q guess-wheel-triple)
        if [[ "${ON_WINDOWS}" ]]; then
            fn=$(just guess-wheel-latest "{{shell('cygpath --windows "{{dist_dir}}"')}}"\\${triple}.whl)
        else
            fn=$(just guess-wheel-latest "{{dist_dir}}"/${triple}.whl)
        fi
        {{test_pip_cmd}} install --force-reinstall "$fn[test]"
    fi

guess-package-path python='python3' package='doesnotexist':
    #!{{python}}
    import importlib
    import os
    import sys

    package = "{{package}}"
    if not package or package == "doesnotexist":
        print("package argument cannot be empty", file=sys.stderr)
        exit(1)

    try:
        module = importlib.import_module(package)
        print(os.path.normpath(os.path.dirname(module.__file__)))
    except Exception as e:
        print(f"{__file__}: invalid package: '{package}' ({e})", file=sys.stderr)
        exit(2)

[positional-arguments]
test +TARGET='': build test-install-deps
    #!{{shebang}}
    set -euo pipefail

    mkdir -p "$test_jail"
    cd "$test_jail"
    export HOME="$test_jail"

    install_dir="$(just guess-package-path {{test_python_cmd}} {{project_name}})"
    if [[ "${ON_WINDOWS}" ]]; then
        install_dir="$(cygpath --unix $(just guess-package-path {{test_python_cmd}} {{project_name}}))"
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

        just ${target}-install-deps
    done

    set -x
    {{test_pytest_cmd}} ${args[@]} "${install_dir}"

test-clean:
    rm -f coverage.xml
    rm -f result.xml
    rm -rf "$test_jail"
