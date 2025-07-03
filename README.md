
# VASP Binary Search for Target Pressure via Volume Optimization

 USAGE: vasp_pressure_search <temperature> <expected_volume> <target_pressure>

 EXAMPLE: ./Binary_press_vol-funt.sh 3000 3500 50
         (Search for 50 kB pressure at 3000K around 3500 Ang³ volume)

# REQUIREMENTS:
- POSCAR file in current directory
 - VASP executable (vasp_std) in PATH
 - POTCAR files in $HOME/POTs/ELEMENT/ directory
 - Running in SLURM environment with srun

