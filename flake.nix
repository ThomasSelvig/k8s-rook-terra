{
  description = "Development environment with DevOps tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; # Or a specific stable release
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Define the packages for the development environment and Docker image
        devPackages = with pkgs; [
          terraform
          ansible
          docker # Docker client, not the daemon
          kubernetes-helm
          kubectl
          bashInteractive # Ensures a good interactive bash shell
        ];
      in
      {
        # Development Shell (usable with `nix develop`)
        devShells.default = pkgs.mkShell {
          name = "devops-shell";
          buildInputs = devPackages ++ [
            pkgs.nix # For Nix commands within the shell
          ];
          shellHook = ''
            echo "Entering DevOps Nix Shell..."
            echo "Available tools: Terraform, Ansible, Docker, Kubectl, Helm, Bash"
          '';
        };

        # Docker Image
        packages.devops-docker-image = pkgs.dockerTools.buildImage {
          name = "devops-env";
          tag = "latest";
          copyToRoot = pkgs.buildEnv {
            name = "image-root";
            paths = devPackages;
            pathsToLink = [ "/bin" ]; # Link binaries to /bin for easier access
          };
          config = {
            Cmd = [ "${pkgs.bashInteractive}/bin/bash" ]; # Default command to start bash
            WorkingDir = "/work"; # Default working directory inside the container
            # Note: Mounting host directories is done at `docker run` time, not in the image definition.
            # The image will contain the tools, and you map volumes when you create a container.
          };
        };

        # Convenience alias for building the Docker image
        # Use: `nix build .#docker`
        packages.docker = self.packages.${system}.devops-docker-image;
      }
    );
}
