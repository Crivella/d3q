!
! Written by Lorenzo Paulatto (2016) IMPMC @ UPMC / CNRS UMR7590
!  Dual licenced under the CeCILL licence v 2.1
!  <http://www.cecill.info/licences/Licence_CeCILL_V2.1-fr.txt>
!  and under the GPLv2 licence and following, see
!  <http://www.gnu.org/copyleft/gpl.txt>
!
MODULE import_shengbte_module
  USE kinds, ONLY : DP
#include "mpi_thermal.h"
  IMPLICIT NONE
  !
  CONTAINS
  !
  ! Read FORCE_CONSTANTS_3RD files created by ShengBTE "thirdorder" 
  ! (and possibly Phono_shengbte) as documented at 
  ! <https://bitbucket.org/sousaw/shengbte/src/master/README.md>
  SUBROUTINE read_shengbte(filefc3, fc, S)
    USE fc3_interpolate,  ONLY : grid
    USE input_fc,         ONLY : ph_system_info
    USE constants,        ONLY : ANGSTROM_AU, RYTOEV
    IMPLICIT NONE
    CHARACTER(len=*),INTENT(in) :: filefc3
    TYPE(grid), INTENT(inout) :: fc
    TYPE(ph_system_info),INTENT(in) :: S
    CHARACTER(len=8) :: sub = "read_shengbte"
    INTEGER :: u, iR, iR2, n_R
    REAL(DP) :: R2(3), R3(3), F
    INTEGER :: i1,i2,i3, j1,j2,j3, na1,na2,na3, jn1,jn2,jn3
    INTEGER, EXTERNAL :: find_free_unit
    CHARACTER (LEN=6), EXTERNAL :: int_to_char
    REAL(DP),PARAMETER :: F_FACTOR= 1._dp/RYTOEV/ANGSTROM_AU**3
    !
    !n_R = NINT(DSQRT(DBLE(n_R)))
    !IF(n_R**2/=n_R) CALL errore(sub, "problem with R and n_R", 1)
    
    u = find_free_unit()
    OPEN(unit=u, file=filefc3, status='OLD', form='FORMATTED')
      READ(u,*) n_R
      ALLOCATE(fc%yR2(3,n_R), fc%yR3(3,n_R))
      ALLOCATE(fc%xR2(3,n_R), fc%xR3(3,n_R))
      ALLOCATE(fc%FC(3*S%nat,3*S%nat,3*S%nat,n_R))
      fc%xR2 = 0._dp
      fc%xR3 = 0._dp
      fc%yR2 = 0
      fc%yR3 = 0
      fc%FC  = 0._dp
      fc%n_R = n_R
      WRITE(stdout,*) "reading "//TRIM(int_to_char(n_R))//" blocks"
      DO iR = 1, n_R
        READ(u,*)
        READ(u,*) iR2
        IF(iR/=iR2) CALL errore(sub,"i does not match i2", 1)
        READ(u,*) R2
        READ(u,*) R3
        R2 = R2*ANGSTROM_AU/S%celldm(1)
        R3 = R3*ANGSTROM_AU/S%celldm(1)
        !WRITE(stdout,*) iR
        !WRITE(stdout,'(2(3f12.6,5x))') R2,R3
        fc%xR2(:,iR) = R2
        fc%xR3(:,iR) = R3
        CALL cryst_to_cart(1,R2,S%bg,-1)
        CALL cryst_to_cart(1,R3,S%bg,-1)
        !WRITE(stdout,'(2(3f12.6,5x))') R2,R3
        fc%yR2(:,iR) = NINT(R2)
        fc%yR3(:,iR) = NINT(R3)
        
        READ(u,*) na1, na2, na3
        DO j1=1,3
        jn1 = j1 + (na1-1)*3
        DO j2=1,3     
        jn2 = j2 + (na2-1)*3
        DO j3=1,3     
        jn3 = j3 + (na3-1)*3
          READ(u,*) i1,i2,i3, F
          IF(i1/=j1 .or. i2/=j2 .or. i3/=j3) CALL errore(sub, "unexpected i/=j", 1)
          fc%FC(jn1,jn2,jn3,iR) = F*F_FACTOR
        ENDDO
        ENDDO
        ENDDO
      ENDDO
    CLOSE(u)
  END SUBROUTINE
  ! \/o\________\\\________________\\/\_________________________/^>
  FUNCTION guess_nq(nR, yR2, yR3) RESULT(nq)
    IMPLICIT NONE
    INTEGER,INTENT(in) :: nR
    INTEGER,INTENT(in) :: yR2(3,nR), yR3(3,nR)
    INTEGER :: nq(3)
    nq(1) = MAXVAL( (/ MAXVAL(ABS(yR2(1,:))),MAXVAL(ABS(yR3(1,:)))/))
    nq(2) = MAXVAL( (/ MAXVAL(ABS(yR2(2,:))),MAXVAL(ABS(yR3(2,:)))/))
    nq(3) = MAXVAL( (/ MAXVAL(ABS(yR2(3,:))),MAXVAL(ABS(yR3(3,:)))/))
    RETURN
  END FUNCTION
  !
END MODULE


PROGRAM import_shengbte
  USE fc3_interpolate, ONLY : grid
  USE input_fc,        ONLY : read_system, ph_system_info
  USE ph_system,       ONLY : aux_system
  USE import_shengbte_module
  USE f3_bwfft
  USE cmdline_param_module
  IMPLICIT NONE
  INTEGER :: ios, far
  CHARACTER(len=:),ALLOCATABLE :: cmdline
  CHARACTER(len=512) :: argv
  CHARACTER(len=256) :: filefc3, filefc2, fileout_good !, fileout_bad
  TYPE(grid) :: fc, fcb
  TYPE(ph_system_info) :: S
  !
  INTEGER :: nq(3), nq_trip
  TYPE(d3_list),ALLOCATABLE :: d3grid(:)
  LOGICAL :: writed3
  !
  filefc3 = cmdline_param_char("i", "FORCE_CONSTANTS_3RD")
  filefc2 = cmdline_param_char("s", "mat2R")
  fileout_good = cmdline_param_char("o", "mat3R.shengbte")
  far      = cmdline_param_int("f", 2)
  writed3  = cmdline_param_logical("w")
  !
  IF(cmdline_param_logical('h'))THEN
    WRITE(*,'(a)') "d3_import_shengbte.x [-i FORCE_CONSTANTS_3RD] [-s HEADER] [-o FILEOUT] [-f NFAR] [-w] NQX NQY NQZ"
    WRITE(*,'(5x,a)') "Import the 3-body force constants generated by the thirdorder code of"
    WRITE(*,'(5x,a)') "Mingo & Carrete."
    WRITE(*,*)
    WRITE(*,'(5x,a)') "Per default, it reads the FCs from a file called FORCE_CONSTANTS_3RD"
    WRITE(*,'(5x,a)') "and the system information, in the format generated by d3_q2r.x or"
    WRITE(*,'(5x,a)') "d3_qq2rr.x, from a file called mat2R (an actual file generated by d3_q2r.x"
    WRITE(*,'(5x,a)') "works fine)"
    WRITE(*,*)
    WRITE(*,'(5x,a)') "The supercell size, as specified to thirdorder.py must be given on command"
    WRITE(*,'(5x,a)') "line as NQX NQY NQZ."
    WRITE(*,*)
    WRITE(*,'(5x,a)') "The resulting force constant will be re-centered using up to NFAR (default: 2)"
    WRITE(*,'(5x,a)') "neighbouring cells and written to FILEOUT (default: mat3R)"
    WRITE(*,*)
    WRITE(*,'(5x,a)') "If '-w' is specified, write the intermediate D3 matrices to files called"
    WRITE(*,'(5x,a)') "atmp_Q1*_Q2*_Q3* (default: don't write, lot of output!)"
    STOP 1
  ENDIF
  cmdline = cmdline_residual()
  READ(cmdline, *, iostat=ios) nq
  IF(ios/=0) CALL errore("import_shengbte", "missing argument use command '-h' for help",1)
  
  OPEN(unit=999,file=filefc2,action='READ',status='OLD')
  CALL read_system(999, S)
  CALL aux_system(S)
  ! Do no write the phonon effective charges to the D3 file:
  S%lrigid = .false.
  CLOSE(999)
  !
  !CALL scan_shengbte(filefc3, S)
  CALL read_shengbte(filefc3, fc, S)

  WRITE(*,*)

  IF(far==0)THEN
    ! In this case, recentering is not required, we can dump the force constants as is
    WRITE(*,*) "Skipping recentering and saving 3-body FCs to file."
    CALL fc%write(fileout_good, S)
  ELSE 
    !
    !
    ! Here we do a forward FFT from the force constants to the equivalent grid 
    ! of triplets. We are just doing Fourier transform here, not Fourier interpolation.
    ! Hence, hhe grid nq must be of the same size as the number of neighbours of FC, 
    ! or this will introduce huge aliasing errors!
    !
    WRITE(*,*) "Doing a back-and-forward Fourier transform to center the 3-body FCs."
    !
    nq_trip = (nq(1)*nq(2)*nq(3))**2
    ALLOCATE(d3grid(nq_trip))
    CALL regen_fwfft_d3(nq, nq_trip, S, d3grid, fc, writed3)
    !
    ! Now we take the grid of triplets and do a backward FFT with recentering,
    ! this produces a new set of FCs (fcb) which are fit for Fourier interpolation.
    !
    CALL bwfft_d3_interp(nq, nq_trip, S%nat, S%tau, S%at, S%bg, d3grid, fcb, far, 1)
    fcb%nq = fc%nq
    CALL fcb%write(fileout_good, S)
  ENDIF
  !
  !
END PROGRAM
!
