# Oracle Instance Creator Configuration Guide

This document provides comprehensive information about configuring and using the Oracle Instance Creator after the refactoring.

## Overview

The Oracle Instance Creator has been refactored into a modular architecture with separate scripts for different functions, structured configuration files, and enhanced error handling.

## Architecture

### File Structure
```
├── .github/workflows/
│   └── free-tier-creation.yml     # Simplified GitHub Actions workflow
├── scripts/
│   ├── setup-oci.sh               # OCI CLI configuration
│   ├── setup-ssh.sh               # SSH key configuration
│   ├── validate-config.sh         # Configuration validation
│   ├── launch-instance.sh         # Instance creation logic
│   ├── notify.sh                  # Telegram notifications
│   └── utils.sh                   # Common utility functions
├── config/
│   ├── instance-profiles.yml      # Pre-defined instance configurations
│   ├── defaults.yml               # Default values and validation rules
│   └── regions.yml                # Region and availability domain reference
└── docs/
    └── configuration.md           # This file
```

### Workflow Jobs

The GitHub Actions workflow consists of two focused jobs with secure credential handling:

1. **create-instance**: Validates configuration, sets up environment, and creates OCI instance (all in one job for security)
2. **notify-on-failure**: Sends failure notifications if the main job fails

**Security Note**: All credential operations occur within a single job to avoid storing sensitive data in artifacts between jobs.

## Configuration

### Required GitHub Secrets

All secrets must be configured in your GitHub repository settings:

| Secret Name | Description | Example |
|-------------|-------------|---------|
| `OCI_USER_OCID` | Your OCI user OCID | `ocid1.user.oc1..aaaa...` |
| `OCI_KEY_FINGERPRINT` | API key fingerprint | `12:34:56:78:90:ab:cd:ef...` |
| `OCI_TENANCY_OCID` | Your OCI tenancy OCID | `ocid1.tenancy.oc1..aaaa...` |
| `OCI_REGION` | OCI region identifier | `ap-singapore-1` |
| `OCI_PRIVATE_KEY` | Private API key content | `-----BEGIN RSA PRIVATE KEY-----...` |
| `OCI_SUBNET_ID` | Target subnet OCID | `ocid1.subnet.oc1..aaaa...` |
| `INSTANCE_SSH_PUBLIC_KEY` | SSH public key for access | `ssh-rsa AAAA...` |
| `TELEGRAM_TOKEN` | Telegram bot token | `123456:ABC-DEF...` |
| `TELEGRAM_USER_ID` | Telegram user ID | `123456789` |

### Optional GitHub Secrets

| Secret Name | Description | Default |
|-------------|-------------|---------|
| `OCI_COMPARTMENT_ID` | Target compartment OCID | Uses tenancy OCID |
| `OCI_IMAGE_ID` | Specific image OCID | Auto-discovered |

### Environment Variables

These can be set in the GitHub Actions workflow file:

| Variable | Description | Default |
|----------|-------------|---------|
| `OCI_AD` | Availability domain | `fgaj:AP-SINGAPORE-1-AD-1` |
| `OCI_SHAPE` | Instance shape | `VM.Standard.A1.Flex` |
| `OCI_OCPUS` | Number of OCPUs (flexible shapes) | `4` |
| `OCI_MEMORY_IN_GBS` | Memory in GB (flexible shapes) | `24` |
| `INSTANCE_DISPLAY_NAME` | Instance display name | `a1-sg` |
| `ASSIGN_PUBLIC_IP` | Assign public IP | `true` |
| `OPERATING_SYSTEM` | Operating system | `Oracle Linux` |
| `OS_VERSION` | OS version | `10` |

## Using Instance Profiles

Instance profiles allow you to pre-define common configurations in `config/instance-profiles.yml`.

### Available Profiles

- `arm-singapore`: Default ARM instance in Singapore
- `amd-singapore`: AMD micro instance in Singapore  
- `arm-singapore-public`: ARM instance with public IP
- `arm-frankfurt`: ARM instance in Frankfurt
- `arm-ubuntu`: ARM Ubuntu instance

### Using a Profile

To use a profile, you would typically modify the workflow or create a script that loads the profile configuration. The profiles are currently for reference and future enhancement.

## Error Handling

The refactored system includes comprehensive error classification:

### Error Types

1. **CAPACITY**: No capacity available (not treated as failure)
2. **AUTH**: Authentication/authorization errors
3. **CONFIG**: Configuration errors (invalid OCIDs, missing resources)
4. **NETWORK**: Network connectivity issues
5. **UNKNOWN**: Other unclassified errors

### Retry Logic

- Network errors: Retry with exponential backoff
- Capacity errors: Silent retry on next scheduled run
- Configuration/Auth errors: Immediate failure with notification

## Notifications

### Telegram Integration

The notification system sends structured messages for:

- Instance creation success
- Configuration errors
- Authentication failures
- Network issues
- Capacity unavailability
- Workflow status updates

### Message Format

All notifications include:
- Timestamp
- Error/success type with emoji
- Detailed context information
- Suggested actions when applicable

## Scripts Usage

### Individual Script Usage

All scripts can be run independently for testing:

```bash
# Validate configuration
./scripts/validate-config.sh

# Setup OCI configuration
./scripts/setup-oci.sh

# Setup SSH configuration  
./scripts/setup-ssh.sh

# Launch instance
./scripts/launch-instance.sh

# Test Telegram notifications
./scripts/notify.sh test
```

### Environment Variables for Scripts

When running scripts locally, set these environment variables:

```bash
export OCI_USER_OCID="ocid1.user.oc1..aaaa..."
export OCI_KEY_FINGERPRINT="12:34:56:78:90:ab:cd:ef..."
# ... (all other required variables)
export DEBUG="true"  # For debug output
```

## Troubleshooting

### Common Issues

1. **Invalid OCID Format**
   - Error: `Invalid OCI_USER_OCID format`
   - Solution: Verify OCID format matches pattern `ocid1.type.region.realm.id`

2. **SSH Key Format**
   - Error: SSH public key validation warnings
   - Solution: Ensure key starts with `ssh-rsa`, `ssh-ed25519`, etc.

3. **Capacity Errors**
   - Error: `No capacity available`
   - Solution: This is expected - the workflow will retry automatically

4. **Telegram Notifications Not Working**
   - Error: Telegram API errors
   - Solution: Verify bot token and user ID are correct

### Debug Mode

Enable debug logging by setting workflow input `verbose_output` to `true` or setting `DEBUG=true` environment variable for local testing.

### Log Analysis

Check the following for troubleshooting:
- GitHub Actions workflow logs
- Script exit codes
- Telegram notification status
- OCI CLI error messages

## Security Considerations

1. **Private Keys**: Never commit private keys to the repository
2. **Secrets Management**: Use GitHub Secrets for sensitive information
3. **File Permissions**: Scripts automatically set correct permissions for OCI config files
4. **Network Security**: Consider IP restrictions on OCI resources

## Migration from Original

### Changes Made

1. **Modular Architecture**: Single monolithic workflow split into focused scripts
2. **Enhanced Validation**: Comprehensive input validation with clear error messages
3. **Better Error Handling**: Classified error responses with appropriate actions
4. **Configuration Management**: Structured configuration files for different scenarios
5. **Improved Notifications**: Rich Telegram messages with context and emojis

### Backwards Compatibility

- All existing GitHub Secrets are still used
- Same functionality with improved reliability
- Enhanced error messages and logging
- No changes to external dependencies

## Future Enhancements

Possible future improvements:

1. **Profile Selection**: Allow workflow to select instance profiles dynamically
2. **Multi-Region Support**: Deploy to multiple regions with fallback
3. **Resource Monitoring**: Track and report on resource usage
4. **Advanced Retry Logic**: Smart retry strategies based on error patterns
5. **Configuration Validation API**: REST API for validating configurations

## Support

For issues with the Oracle Instance Creator:

1. Check GitHub Actions workflow logs
2. Verify all required secrets are configured
3. Test individual scripts locally if possible
4. Review Telegram notifications for detailed error information
5. Consult OCI documentation for service-specific issues