# build-aur-packages

GitHub Action that builds AUR packages and provides the built packages as
package repository in the GitHub workspace.
From there, other actions can use the package repository to install packages
or upload the repository to some share or ...

See [nafets227/archPackages](https://github.com/nafets227/archPackages) for a
real world example

Usage:
Use this in a job that allows to run Docker (e.g. Linux machine) like this:

```yaml
jobs:
  build_repository:
    runs-on: ubuntu-latest
    steps:
    - name: Build Packages
      uses: nafets227build-aur-packages
      with:
        packages: >
          azure-cli
          kwallet-git
          micronucleus-git
        missing_pacman_dependencies: >
          libusb-compat
```

This example will build packages

```text
          azure-cli
          kwallet-git
          micronucleus-git
```

Since the package `micronucleus-git` has the dependencies not properly
declared, you can force `pacman` to install the missing dependency by passing
it to `missing_pacman_dependencies`.
If a dependency from AUR is missing, you can pass this to
`missing_aur_dependencies`.

The resulting repository information will be copied to the GitHub workspace.

## Development

To build a package and create the corresponding repository files, build the
Docker image

```shell
    docker build -t builder .
````

then run it, passing the packages as environment variables.
The names of the variables are derived from the `action.yaml`.

```shell
    mkdir workspace
    docker run --rm -it \
        -v $(pwd)/workspace:/workspace \
        -e "GITHUB_WORKSPACE=/workspace" -e "INPUT_PACKAGES=go-do" \
        builder
```
