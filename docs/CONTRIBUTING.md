# Contributing to Fusion HCI Multi-Architecture Integration

Thank you for your interest in contributing! This document provides guidelines for contributing to the project.

## Code of Conduct

- Be respectful and inclusive
- Focus on constructive feedback
- Help others learn and grow
- Maintain a professional environment

## How to Contribute

### Reporting Issues

1. **Search existing issues** to avoid duplicates
2. **Use issue templates** when available
3. **Provide details**:
   - OpenShift versions (main cluster and HCI cluster)
   - Deployment variant (z/VM or KVM)
   - Error messages and logs
   - Steps to reproduce

### Suggesting Enhancements

1. **Check the roadmap** in [Operator Roadmap](development/operator-roadmap.md)
2. **Open a discussion** for major changes
3. **Describe the use case** and benefits
4. **Consider backwards compatibility**

### Contributing Code

#### Getting Started

1. **Fork the repository**
2. **Clone your fork**:
   ```bash
   git clone https://github.com/your-username/fusion-hci-integration.git
   cd fusion-hci-integration
   ```
3. **Create a branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```

#### Development Guidelines

**Documentation**:
- Update documentation for any user-facing changes
- Use clear, concise language
- Include examples where appropriate
- Test documentation builds: `mkdocs serve`

**Configuration Files**:
- Never commit credentials or sensitive data
- Use `.example` suffix for template files
- Update `.gitignore` if needed
- Validate YAML syntax

**Kustomize Overlays**:
- Keep base resources generic
- Use overlays for variant-specific changes
- Test with `kubectl kustomize`
- Document overlay purpose in README

**Scripts**:
- Use bash with error handling (`set -euo pipefail`)
- Add usage documentation
- Make scripts idempotent where possible
- Test on both Mediated and Direct topology variants

#### Testing

**Before submitting**:
1. Test your changes in a real environment
2. Verify both Mediated and Direct topology variants (if applicable)
3. Check documentation builds without errors
4. Run any existing tests

**Test checklist**:
- [ ] Gateway VM deploys successfully
- [ ] Worker VMs join the cluster
- [ ] Network connectivity works
- [ ] Documentation is accurate
- [ ] No credentials in commits

#### Commit Messages

Follow conventional commits format:

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types**:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `refactor`: Code refactoring
- `test`: Test additions/changes
- `chore`: Maintenance tasks

**Examples**:
```
feat(operator): add support for custom storage class

Add storageClassName parameter to worker VM template
to allow users to specify custom storage classes.

Closes #123
```

```
docs(direct): clarify master route configuration

Improve documentation for Direct Topology master node
routing setup with troubleshooting steps.
```

#### Pull Request Process

1. **Update documentation** for any user-facing changes
2. **Update CHANGELOG.md** (if applicable)
3. **Ensure tests pass** (manual testing required)
4. **Request review** from maintainers
5. **Address feedback** promptly
6. **Squash commits** if requested

**PR Description Template**:
```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Documentation update
- [ ] Refactoring

## Testing
- [ ] Tested on Mediated Topology variant
- [ ] Tested on Direct Topology variant
- [ ] Documentation builds successfully
- [ ] No credentials in commits

## Related Issues
Closes #<issue-number>

## Screenshots (if applicable)
```

### Contributing Documentation

Documentation is crucial! We welcome:
- Typo fixes and clarifications
- Additional examples
- Troubleshooting guides
- Architecture diagrams
- Tutorial improvements

**Documentation structure**:
```
docs/
├── index.md                    # Landing page
├── getting-started.md          # Quick start guide
├── prerequisites.md            # Requirements
├── deployment-variants.md      # z/VM vs KVM
├── architecture/               # Architecture docs
├── configuration/              # Configuration guides
├── operations/                 # Operational guides
└── development/                # Developer guides
```

**Building docs locally**:
```bash
pip install mkdocs-material
mkdocs serve
# Open http://localhost:8000
```

### Areas Needing Contribution

#### High Priority
- [ ] Additional deployment examples
- [ ] Troubleshooting scenarios
- [ ] Performance tuning guides
- [ ] Security hardening documentation

#### Medium Priority
- [ ] Monitoring and alerting setup
- [ ] Backup and recovery procedures
- [ ] Upgrade procedures
- [ ] Multi-cluster examples

#### Future Work
- [ ] Operator development (see [Operator Roadmap](development/operator-roadmap.md))
- [ ] ARM architecture support
- [ ] Power architecture support
- [ ] Automated testing framework

## Development Environment

### Required Tools
- `oc` or `kubectl` CLI
- `kustomize` (or `kubectl kustomize`)
- `mkdocs` with material theme
- Access to OpenShift clusters (main + HCI)

### Recommended Tools
- `yamllint` for YAML validation
- `shellcheck` for shell script linting
- `pre-commit` hooks (optional)

## Style Guidelines

### YAML
- Use 2 spaces for indentation
- Quote strings when necessary
- Use `---` document separator
- Add comments for complex configurations

### Markdown
- Use ATX-style headers (`#`)
- Add blank lines around code blocks
- Use fenced code blocks with language tags
- Keep lines under 120 characters (soft limit)

### Shell Scripts
- Use `#!/bin/bash` shebang
- Add `set -euo pipefail` for safety
- Use meaningful variable names
- Add usage documentation
- Quote variables: `"${VAR}"`

## Security

### Reporting Security Issues
**Do not** open public issues for security vulnerabilities.

Contact maintainers privately:
- Email: OpenShift-on-Z team (via GitHub Issues marked as security)
- Include detailed description and reproduction steps

### Security Best Practices
- Never commit credentials
- Use secrets management (Sealed Secrets, Vault, etc.)
- Follow principle of least privilege
- Keep dependencies updated
- Review security implications of changes

## Questions?

- **Documentation**: Check the [documentation site](https://IBM.github.io/fusion-hci-integration/)
- **Discussions**: Use GitHub Discussions
- **Issues**: Search existing issues
- **Chat**: Join our community chat (if available)

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.

---

Thank you for contributing to make multi-architecture OpenShift deployments easier!