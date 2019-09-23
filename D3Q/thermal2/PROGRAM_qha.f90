!
! Written by Lorenzo Paulatto (2019) IMPMC @ SU / CNRS UMR7590
!  Dual licenced under the CeCILL licence v 2.1
!  <http://www.cecill.info/licences/Licence_CeCILL_V2.1-fr.txt>
!  and under the GPLv2 licence and following, see
!  <http://www.gnu.org/copyleft/gpl.txt>
!
MODULE qha_program

  USE timers
  USE kinds,            ONLY : DP
  USE fc2_interpolate,  ONLY : freq_phq, freq_phq_safe, freq_phq, &
                               freq_phq_positive, &
                               forceconst2_grid, set_nu0
  USE input_fc,           ONLY : ph_system_info, read_fc2, aux_system, div_mass_fc2

#include "mpi_thermal.h"

  TYPE qha_input_type
    !
    CHARACTER(len=16) :: calculation ! gibbs, grun
    CHARACTER(len=256) :: outdir
    CHARACTER(len=256) :: prefix
    REAL(DP),POINTER :: nrg_v(:)
    !REAL(DP),POINTER :: press_v(:)
    INTEGER :: n_volumes = -1
    ! 
    CHARACTER(len=6) :: grid_type
    INTEGER :: nk(3) = -1
    !REAL(DP) :: smearing = -1._dp
    !
    REAL(DP) :: T0, dT 
    INTEGER :: nT
    CHARACTER(len=8)  :: asr2
    !
  END TYPE qha_input_type
  !
  CONTAINS
  !
  ! read everything from files mat2R and mat3R
  SUBROUTINE READ_INPUT_QHA(input, S, fc2)
    USE q_grids,              ONLY : q_grid, setup_simple_grid
    USE constants,            ONLY : RY_TO_CMM1, RY_KBAR
    USE more_constants,       ONLY : INVALID, write_conf
    USE wrappers,             ONLY : f_mkdir_safe
    USE code_input,           ONLY : parse_command_line
    USE fc2_interpolate,      ONLY : forceconst2_grid, freq_phq_safe
    USE asr2_module,          ONLY : impose_asr2
    USE cmdline_param_module, ONLY : cmdline_to_namelist
    !
    IMPLICIT NONE
    !
    TYPE(qha_input_type),INTENT(out) :: input
    TYPE(forceconst2_grid),INTENT(out),ALLOCATABLE :: fc2(:)
    TYPE(ph_system_info),INTENT(out),ALLOCATABLE   :: S(:)
    CHARACTER(len=256)  :: input_file
    INTEGER :: ios
    !
    ! Input variable, and defaul values:
    CHARACTER(len=16)   :: calculation = "gibbs"
    CHARACTER(len=256)  :: outdir = "./" 
    CHARACTER(len=256)  :: prefix = INVALID    ! add to the name of the first file to create out file
    CHARACTER(len=256),ALLOCATABLE :: mat2R_v(:)
    !
    CHARACTER(len=8)    :: asr2 = "simple"
    INTEGER             :: n_volumes = -1
    CHARACTER(len=6) :: grid_type
    INTEGER          :: nk(3) = -1
!    REAL(DP)         :: T = -1._dp
    REAL(DP)         :: T0=0._dp, dT=100._dp
    INTEGER          :: nT = 6
!    REAL(DP)         :: smearing = -1._dp
    !
    INTEGER :: i, input_unit, aux_unit
    CHARACTER(len=6), EXTERNAL :: int_to_char
    INTEGER,EXTERNAL :: find_free_unit
    !
    NAMELIST  / qhainput / &
      calculation, outdir, prefix, &
      asr2, &
      n_volumes, T0, dT, nT, &
      nk, grid_type
      
    WRITE(*,*) "Waiting for input"
    !
    input_file="input.QHA"
    CALL parse_command_line(input_file)
    IF(TRIM(input_file)=="-")THEN
      ioWRITE(stdout,'(2x,3a)') "Warning! Reading standard input will probably not work with MPI"
      input_unit = 5
    ELSE
      ioWRITE(stdout,'(2x,3a)') "Reading input file '", TRIM(input_file), "'"
      input_unit = find_free_unit()
      OPEN(unit=input_unit, file=input_file, status="OLD", action="READ")
    ENDIF
    !
    aux_unit = find_free_unit()
    READ(input_unit, qhainput)
    WRITE(stdout,'(2x,3a)') "merging with command line arguments"
    OPEN(unit=aux_unit, file=TRIM(input_file)//".tmp~", status="UNKNOWN", action="READWRITE")
    CALL cmdline_to_namelist("qhainput", aux_unit)
    REWIND(aux_unit)
    READ(aux_unit, qhainput)
    CLOSE(aux_unit, status="DELETE")

    WRITE(stdout, qhainput)
    !
    IF(ANY(nk<1))  CALL errore("READ_INPUT_QHA","Invalid nk",1)
!    IF(T<0)        CALL errore("READ_INPUT_QHA","Invalid T",1)
!    IF(smearing<0) CALL errore("READ_INPUT_QHA","Invalid smearing",1)

    !
    input%calculation         = calculation
    input%prefix              = prefix
    input%outdir              = outdir
    input%asr2                = asr2
    !
    input%n_volumes           = n_volumes
    input%T0                  = T0
    input%dT                  = dT
    input%nT                  = nT
    input%nk                  = nk 
    input%grid_type           = grid_type
    !
    ios = f_mkdir_safe(input%outdir)
    !
    ALLOCATE(mat2R_v(n_volumes))
    ALLOCATE(input%nrg_v(n_volumes))
    !ALLOCATE(input%press_v(n_volumes))
    ALLOCATE(S(n_volumes))
    ALLOCATE(fc2(n_volumes))
    DO i = 1,n_volumes
      READ(input_unit,*) mat2R_v(i), input%nrg_v(i) !, input%press_v(i)
      CALL read_fc2(mat2R_v(i), S(i),  fc2(i))
      CALL impose_asr2(input%asr2, S(i)%nat, fc2(i), S(i)%zeu)
      CALL aux_system(S(i))
      CALL div_mass_fc2(S(i), fc2(i))
    ENDDO
    !input%press_v = input%press_v/RY_KBAR
    CLOSE(input_unit)
    !
  END SUBROUTINE READ_INPUT_QHA

  ! gibbs free energy
  SUBROUTINE GIBBS(input, S, fc2)
    USE q_grids,        ONLY : q_grid, setup_grid
    USE constants,      ONLY : RY_TO_CMM1, K_BOLTZMANN_RY
    USE more_constants, ONLY : write_conf
    !
    IMPLICIT NONE
    !
    TYPE(qha_input_type),INTENT(in)   :: input
    TYPE(forceconst2_grid),INTENT(in) :: fc2(input%n_volumes)
    TYPE(ph_system_info),INTENT(in)   :: S(input%n_volumes)
    !
    REAL(DP) :: weight, wbeta, T(input%nT)
    REAL(DP) :: e_zp(input%n_volumes), e_ts(input%n_volumes, input%nT), &
                g(input%n_volumes), g_fit(input%n_volumes), vol(input%n_volumes)
    REAL(DP) :: g0(input%nT), v0(input%nT), k0(input%nT), dk0(input%nT), d2k0(input%nT), aV_T(input%nT)
    REAL(DP),ALLOCATABLE :: freq(:)
    COMPLEX(DP),ALLOCATABLE :: U(:,:)
    INTEGER :: iq, nu, iv, nu0, iT !, iv_min
    TYPE(q_grid) :: grid
    CHARACTER(len=256) :: filename
    !
    DO iT = 1, input%nT
      T(iT) = input%T0 + (iT-1)*input%dT
    ENDDO
    FORALL(iv=1:input%n_volumes) vol(iv) = S(iv)%omega
    !
    ALLOCATE(freq(S(1)%nat3))
    ALLOCATE(U(S(1)%nat3,S(1)%nat3))


    WRITE(*,'("Computing zero-point and phonon-free energy for each volume,")')
    DO iv = 1, input%n_volumes
      WRITE(*,'(i5)',ADVANCE="no") iv
      IF(MOD(iv-1,8)==7 .or. iv==input%n_volumes) WRITE(*,*)
      FLUSH(stdout)
      CALL setup_grid(input%grid_type, S(iv)%bg, input%nk(1), input%nk(2), input%nk(3), grid, scatter=.false., quiet=.true.)
      e_zp(iv) = 0._dp
      e_ts(iv,:) = 0._dp
      DO iq = 1, grid%nq
       !CALL freq_phq_safe(grid%xq(:,iq), S(iv), fc2(iv), freq, U)
       CALL freq_phq_positive(grid%xq(:,iq), S(iv), fc2(iv), freq, U)
       e_zp(iv) = e_zp(iv) + 0.5_dp * grid%w(iq) * SUM(freq)
       nu0  = set_nu0(grid%xq(:,iq), S(iv)%at)
       
       DO iT = 1, input%nT
         weight = grid%w(iq) * T(iT) * K_BOLTZMANN_RY
         DO nu = nu0, S(iv)%nat3
           !IF(freq(nu)/=0._dp) THEN
           wbeta = freq(nu)/(K_BOLTZMANN_RY*T(iT))
           e_ts(iv,iT) = e_ts(iv,iT) + weight *( -DLOG(1-DEXP(-wbeta)))!  + wbeta/(DEXP(wbeta)-1))
           IF(ISNAN( -DLOG(1-DEXP(-wbeta)))) THEN
             print*, "caz!", grid%xq(:,iq)
             print*, "caz?", freq
           ENDIF
           !ENDIF
         ENDDO
       ENDDO
      ENDDO
      CALL grid%destroy()
    ENDDO

    WRITE(*,'("Fitting each temperature curve with EOS and writing to file")')
    DO iT = 1, input%nT
      WRITE(*,'(i5)',ADVANCE="no") iT
      IF(MOD(iT-1,8)==7 .or. iT==input%nT) WRITE(*,*)
      FLUSH(stdout)

      filename  = TRIM(input%outdir)//"/"//TRIM(input%prefix)//"_T"&
                //TRIM(write_conf(iT,input%nT,T))//".dat"
      OPEN(unit=90000+it, file=filename)
      WRITE(90000+iT,*) "# temperature", T(iT) 
      g = input%nrg_v(:) + e_zp(:) - (e_ts(:,iT))
      CALL fit(input%n_volumes, T(iT), vol, g, g_fit, g0(iT), v0(iT), k0(iT), dk0(iT), d2k0(iT))
!      iv_min = MINLOC(g,1)
!      WRITE(90000+iT,*) "# minimum:", iv_min,  S(iv_min)%omega, g(iv_min)
!      WRITE(90000+iT,*) "#", MINVAL(input%nrg_v), MINVAL(e_zp), MINVAL(e_ts(:,iT))
      WRITE(90000+iT,'("#",a21,7a26)') "v0(iT)", "g0(iT)", &
                       "k0(iT)", "dk0(iT)", "d2k0(iT)"
      WRITE(90000+iT,*) "#", v0(iT), g0(iT), k0(iT), dk0(iT), d2k0(iT)
      WRITE(90000+iT,'("#",a21,7a26)') "volume", "gibbs", "electrons", &
                       "zero-point", "TS", "g-g0", "g_fit"
      DO iv = 1, input%n_volumes
        WRITE(90000+iT,*) vol(iv), g(iv), &
                          input%nrg_v(iv), e_zp(iv), -(e_ts(iv,iT)), g(iv)-g0(iT), g_fit(iv)
      ENDDO
      CLOSE(90000+it)
    ENDDO
    !
    ! Volumetric thermal expansion
    IF(input%nT>=2)THEN
        WRITE(*,'("Computing thermal expansion 1/V dV/dT")')
        IF(input%nT>2)THEN
        DO iT = 2, input%nT-1
         aV_T(iT) = (v0(iT+1)-v0(iT-1))/(T(iT+1)-T(iT-1))/v0(iT)
        ENDDO
        ENDIF
        aV_T(1) = (v0(2)-v0(1))/(T(2)-T(1))/v0(1)
        aV_T(input%nT) = (v0(input%nT)-v0(input%nT-1))/(T(input%nT)-T(input%nT-1))/v0(input%nT)
    ELSE
        WRITE(*,'("Cannot compute thermal expansion")')
        aV_T = 0._dp
    ENDIF
    !
    !
    filename  = TRIM(input%outdir)//"/"//TRIM(input%prefix)//".dat"
    OPEN(unit=90000, file=filename)
    WRITE(90000,'("#",a21,7a26)') "Temperature", "volume0", "vol.therm.exp",&
                  "energy0", "bulk mod.", "dbulk", "d2bulk"
    DO iT = 1, input%nT
      WRITE(90000,*) T(iT), v0(iT), aV_T(iT), g0(iT), k0(iT), dk0(iT), d2k0(iT)
    ENDDO
    CLOSE(90000)
    
  END SUBROUTINE GIBBS

  SUBROUTINE fit(nv,T,vol, nrg, nrg_fit, nrg0, vol0, k0, dk0, d2k0)
    USE eos,       ONLY : find_minimum, find_minimum2
    USE constants, ONLY : ry_kbar
    IMPLICIT NONE
    INTEGER,INTENT(in)  :: nv
    REAL(DP),INTENT(in) :: T
    REAL(DP),INTENT(in) :: nrg(nv), vol(nv)
    REAL(DP),INTENT(out):: nrg_fit(nv)
    REAL(DP),INTENT(out) :: nrg0,vol0,k0,dk0,d2k0                        
    REAL(DP) :: chisq, par(4)
    ! 1,3 2,4 3,4 4,3
    CALL find_minimum2(4,3,par,nv,vol,&
                      nrg,nrg_fit,nrg0,chisq)

    vol0 = par(1)
    k0   = par(2)/ry_kbar ! converts k0 to Ry atomic units...
    dk0  = par(3)
    d2k0 = par(4)*ry_kbar ! and d2k0/dp2 to (Ry a.u.)^(-1)
      
    !WRITE(8888,*) T, nrg0, chisq, vol0, k0, dk0, d2k0
        
  END SUBROUTINE
 
END MODULE qha_program
!
!
!
PROGRAM qha 

  USE kinds,            ONLY : DP
  USE qha_program
  USE input_fc,         ONLY : read_fc2, aux_system, div_mass_fc2, &
                              forceconst2_grid, ph_system_info, &
                              multiply_mass_dyn, write_dyn
  USE asr2_module,      ONLY : impose_asr2
  USE constants,        ONLY : RY_TO_CMM1
  USE q_grids,          ONLY : q_grid
  USE ph_velocity,      ONLY : velocity
  USE more_constants,   ONLY : print_citations_linewidth
  USE mpi_thermal,      ONLY : start_mpi, stop_mpi, ionode
  USE nanoclock,        ONLY : init_nanoclock
  IMPLICIT NONE
  !
  TYPE(forceconst2_grid),ALLOCATABLE :: fc2(:) !=> null()
  TYPE(ph_system_info),ALLOCATABLE   :: S(:)   !=> null()
  TYPE(qha_input_type)   :: input
  !
  CHARACTER (LEN=6),  EXTERNAL :: int_to_char
  !
  CALL start_mpi()
  CALL init_nanoclock()
  IF(ionode) CALL print_citations_linewidth()
  !  
  CALL READ_INPUT_QHA(input, S, fc2)
  !
  IF( input%calculation=="gibbs") THEN
    print*, "gibbs!"
    CALL GIBBS(input,S,fc2)
  ENDIF
 CALL stop_mpi()
  
END PROGRAM qha