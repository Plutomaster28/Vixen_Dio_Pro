# Contributing to Vixen Dio Pro

Thank you for your interest in contributing to the Vixen Dio Pro open source x86-64 processor! 🚀

##  **How to Contribute**

### **1. Areas of Contribution**

#### ** Verification & Testing**
- Create comprehensive testbenches
- Add formal verification
- FPGA prototyping
- Performance benchmarking

#### ** Performance Optimization**
- Timing closure improvements
- Power optimization
- Area reduction
- Frequency scaling

#### ** Architecture Enhancements**
- Cache hierarchy integration
- Advanced branch prediction (TAGE)
- Trace cache implementation
- Full x86-64 ISA support

#### ** Documentation**
- Architecture documentation
- Tutorial creation
- Code comments
- User guides

#### ** Tooling & Infrastructure**
- Build system improvements
- CI/CD setup
- Automated testing
- Synthesis optimization

### **2. Getting Started**

1. **Fork** the repository
2. **Clone** your fork
3. **Create** a feature branch
4. **Make** your changes
5. **Test** thoroughly
6. **Submit** a pull request

### **3. Development Environment**

#### **Required Tools**
- OpenLane v1.0.1+
- Sky130 PDK
- Docker
- Git

#### **Optional Tools**
- Verilator (for simulation)
- GTKWave (for waveform viewing)
- Yosys (standalone synthesis)
- KLayout (layout viewing)

### **4. Code Standards**

#### **SystemVerilog Style**
```systemverilog
// Good: Clear, descriptive names
logic [63:0] instruction_address;
logic branch_prediction_valid;

// Bad: Unclear abbreviations
logic [63:0] ia;
logic bpv;
```

#### **Commenting**
```systemverilog
// =============================================================================
// Module: Branch Predictor
// =============================================================================
// Implements a 256-entry bimodal predictor for branch direction prediction
// Compatible with x86-64 branch instruction formats
// =============================================================================

module branch_predictor (
    input  logic        clk,           // System clock
    input  logic        rst_n,         // Active-low reset
    input  logic [63:0] pc,            // Program counter for prediction
    output logic        prediction     // Predicted direction (1=taken)
);
```

#### **File Organization**
```
module_name.sv          # Main module file
├── Header comment      # Purpose, author, license
├── Parameter definitions
├── Port declarations  
├── Internal signals
├── Combinational logic
├── Sequential logic
└── Module instantiations
```

### **5. Testing Requirements**

#### **Before Submitting**
- [ ] Code compiles without errors
- [ ] Passes all existing tests
- [ ] New features include tests
- [ ] Documentation updated
- [ ] Synthesis still passes

#### **Test Types**
- **Unit Tests** - Individual module testing
- **Integration Tests** - Multi-module interaction
- **Synthesis Tests** - OpenLane flow completion
- **Performance Tests** - Timing and area metrics

### **6. Pull Request Process**

#### **PR Template**
```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature  
- [ ] Performance improvement
- [ ] Documentation update
- [ ] Refactoring

## Testing
- [ ] Unit tests pass
- [ ] Integration tests pass
- [ ] Synthesis completes
- [ ] No timing violations

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] Tests added/updated
```

### **7. Release Process**

#### **Version Numbering**
- **Major** (x.0.0) - Architectural changes
- **Minor** (0.x.0) - New features
- **Patch** (0.0.x) - Bug fixes

#### **Release Checklist**
- [ ] All tests passing
- [ ] Documentation complete
- [ ] Synthesis verified
- [ ] Performance benchmarked
- [ ] Release notes written

### **8. Community Guidelines**

#### **Code of Conduct**
- Be respectful and inclusive
- Focus on technical merit
- Help newcomers learn
- Credit contributions properly

#### **Communication**
- Use GitHub Issues for bugs
- Use Discussions for questions
- Be clear and specific
- Provide reproducible examples

##  **Priority Contributions**

### **High Impact**
1. **Testbench Development** - Critical for verification
2. **Timing Closure** - Enable higher frequencies
3. **Cache Integration** - Complete the memory hierarchy
4. **Documentation** - Help others understand the design

### **Good First Issues**
- Add code comments
- Fix coding style issues
- Create simple testbenches
- Update documentation
- Add synthesis constraints

##  **Getting Help**

- **GitHub Issues** - Bug reports and feature requests
- **GitHub Discussions** - Questions and general discussion
- **Documentation** - Check existing docs first
- **Code Comments** - Often explain design decisions

##  **Recognition**

Contributors will be:
- Listed in the contributors file
- Credited in release notes
- Mentioned in documentation
- Appreciated by the community!

---

**Happy Contributing!** 

Your contributions help make advanced processor design accessible to everyone!
