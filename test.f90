
!-------------------------------------------------------------------------------
!  MODULE: Depondt
!> @brief
!> The Depondt solver for the stochastic LLG-equation
!> @authors
!> Anders Bergman
!> @copyright
!> GNU Public License.
!> @details In principle the solver is of Heun type but uses rotations to
!> keep the magnitudes of the moments.
!> Ref: Ph. Depondt and F.G. Mertens, J. Phys.: Condens. Matter 21, 336005 (2009)
!> @todo Replace unit length moment vectors emom with full lenght vector emomM
!-------------------------------------------------------------------------------
module Depondt
   use Profiling
   use Parameters
   use Profiling
   use HamiltonianData
   !
   implicit none
   !
   real(dblprec), dimension(:,:,:), allocatable :: mrod !< Rotated magnetic moments
   real(dblprec), dimension(:,:,:), allocatable :: btherm !< Thermal stochastic field
   real(dblprec), dimension(:,:,:), allocatable :: bloc  !< Local effective field
   real(dblprec), dimension(:,:,:), allocatable :: b_eff_tot   !b_eff+b_therm
   real(dblprec), dimension(:,:,:), allocatable :: bdup !< Resulting effective field

!!!   abstract interface
!!!     function Dmdt(atom,ensemble) result(d)
!!!       import :: dblprec
!!!       integer, intent(in) :: atom,ensemble
!!!       real(dblprec), dimension(3) :: d
!!!     end function Dmdt
!!!   end interface

   private

   public :: depondt_evolve_first, depondt_evolve_second, allocate_depondtfields
   public :: rodmat
 
contains

   !-----------------------------------------------------------------------------
   !> SUBROUTINE: depondt_evolve_first
   !> @brief
   !> First step of Depond solver, calculates the stochastic field and rotates the
   !> magnetic moments according to the effective field
   !
   !> @author Anders Bergman
   !-----------------------------------------------------------------------------
   subroutine depondt_evolve_first(b_eff_tot,damp_local,bdamp_onsite,bdamp_offsite,emomM2,damp_tot_array,do_damptensor,Natom,Nred,Mensemble,lambda1_array,beff,b2eff,   &
      btorque, emom, emom2, emomM, mmom, delta_t, Temp_array, temprescale,stt,      &
      thermal_field,do_she,she_btorque,do_sot,sot_btorque,red_atom_list)
      !
      use Constants, only : k_bolt, gama, mub
      use RandomNumbers, only : rng_gaussian, rng_gaussianP

      implicit none
      !
      integer, intent(in) :: Nred            !< Number of atoms that evolve
      integer, intent(in) :: Natom           !< Number of atoms in system
      integer, intent(in) :: Mensemble       !< Number of ensembles
      real(dblprec), intent(in) :: delta_t   !< Time step
      character(len=1), intent(in) :: STT    !< Treat spin transfer torque?
      character(len=1), intent(in) :: do_she !< Treat the spin hall effect transfer torque
      character(len=1), intent(in) :: do_sot !< Treat the general SOT model
      integer, dimension(Nred), intent(in) :: red_atom_list !< List of indices of atoms that evolve
      real(dblprec), dimension(Natom), intent(in) :: Temp_array !< Temperature (array)
      real(dblprec), dimension(Natom), intent(in) :: lambda1_array !< Damping parameter
      real(dblprec), dimension(Natom,Mensemble), intent(in) :: mmom !< Magnitude of magnetic moments
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: beff !< Total effective field from application of Hamiltonian
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: btorque     !< Spin transfer torque
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: she_btorque !< Spin Hall effect spin transfer torque
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: sot_btorque !< Spin orbit torque
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: bdamp_onsite,bdamp_offsite     !< damping field(damping tensor form)
      real(dblprec), dimension(3,3,Natom,Mensemble), intent(in) :: damp_local    !local damping tensor
      real(dblprec), dimension(3,Natom,Mensemble), intent(out) :: b2eff !< Temporary storage of magnetic field
      real(dblprec), dimension(3,Natom,Mensemble), intent(out) :: emom2 !< Final (or temporary) unit moment vector
      real(dblprec), dimension(3,Natom,Mensemble), intent(out) :: emomM !< Current magnetic moment vector
      real(dblprec), dimension(3,Natom,Mensemble), intent(out) :: emomM2 !< t-1 magnetic moment vector
      real(dblprec), dimension(3,Natom,Mensemble), intent(out) :: b_eff_tot ! beff+btherm
      real(dblprec), dimension(1,Natom,Mensemble), intent(in) :: damp_tot_array !< site total damping 
      integer, intent(in) :: do_damptensor          !< flag do damping tensor
      real(dblprec), intent(inout) :: temprescale  !< Temperature rescaling from QHB
      real(dblprec), dimension(3,Natom,Mensemble), intent(inout) :: emom     !< Current unit moment vector
      real(dblprec), dimension(3,Natom,Mensemble), intent(inout) :: thermal_field

      integer :: i,k,ired
      real(dblprec) :: v,Bnorm,hx,hy,hz
      real(dblprec) :: u,cosv,sinv,lldamp
      real(dblprec) :: sigma, Dp, she_fac, stt_fac,sot_fac

     
      if(do_damptensor/=1) then
         bdup=0.0_dblprec

         if(stt/='N') then
            stt_fac=1.0_dblprec
            !$omp parallel do default(shared) private(i,ired,k)  schedule(static) collapse(2)
            do k=1,Mensemble
               do ired=1,Nred
                  i=red_atom_list(ired)
                  ! Adding STT and SHE torques if present (prefactor instead of if-statement)
                  bdup(:,i,k)=bdup(:,i,k)+stt_fac*btorque(:,i,k)
               end do
            end do
            !$omp end parallel do
         else
            stt_fac=0.0_dblprec
         end if

         if(do_she/='N') then
            she_fac=1.0_dblprec
            !$omp parallel do default(shared) private(i,ired,k)  schedule(static) collapse(2)
            do k=1,Mensemble
               do ired=1,Nred
                  i=red_atom_list(ired)
                  ! Adding STT and SHE torques if present (prefactor instead of if-statement)
                  bdup(:,i,k)= bdup(:,i,k)+she_fac*she_btorque(:,i,k)
               end do
            end do
            !$omp end parallel do
         else
            she_fac=0.0_dblprec
         end if
         if(do_sot/='N') then
            sot_fac=1.0_dblprec
            !$omp parallel do default(shared) private(i,ired,k)  schedule(static) collapse(2)
            do k=1,Mensemble
               do ired=1,Nred
                  i=red_atom_list(ired)
                  ! Adding STT, SHE and SOT torques if present (prefactor instead of if-statement)
                  bdup(:,i,k)= bdup(:,i,k)+sot_fac*sot_btorque(:,i,k)
               end do
            end do
            !$omp end parallel do
         else
            sot_fac=0.0_dblprec
         end if

         call rng_gaussianP(btherm,3*Natom*Mensemble,1.0_dblprec)

         ! Dupont recipe J. Phys.: Condens. Matter 21 (2009) 336005
         !$omp parallel do default(shared) private(ired,i,k,Dp,sigma,Bnorm,hx,hy,hz,v,lldamp,cosv,sinv,u)  schedule(static) collapse(2)
         do k=1,Mensemble
            do ired=1,Nred

               i=red_atom_list(ired)
               ! Thermal field
               !   LL equations ONE universal damping
                
               Dp=(2.0_dblprec*lambda1_array(i)*k_bolt)/(delta_t*gama*mub)   !LLG
               
               sigma=sqrt(Dp*temprescale*Temp_array(i)/mmom(i,k))
               btherm(:,i,k)=btherm(:,i,k)*sigma
              
               ! Construct local field
               bloc(:,i,k)=beff(:,i,k)+btherm(:,i,k)
               thermal_field(:,i,k)=btherm(:,i,k)

               ! Construct effective field (including damping term)
               bdup(1,i,k)=bdup(1,i,k)+bloc(1,i,k)+lambda1_array(i)*emom(2,i,k)*bloc(3,i,k)-lambda1_array(i)*emom(3,i,k)*bloc(2,i,k)
               bdup(2,i,k)=bdup(2,i,k)+bloc(2,i,k)+lambda1_array(i)*emom(3,i,k)*bloc(1,i,k)-lambda1_array(i)*emom(1,i,k)*bloc(3,i,k)
               bdup(3,i,k)=bdup(3,i,k)+bloc(3,i,k)+lambda1_array(i)*emom(1,i,k)*bloc(2,i,k)-lambda1_array(i)*emom(2,i,k)*bloc(1,i,k)
               
               ! Set up rotation matrices and perform rotations
               lldamp=1.0_dblprec/(1.0_dblprec+lambda1_array(i)**2)
               Bnorm=bdup(1,i,k)**2+bdup(2,i,k)**2+bdup(3,i,k)**2
               Bnorm=sqrt(Bnorm)+1.0d-15
               hx=bdup(1,i,k)/Bnorm
               hy=bdup(2,i,k)/Bnorm
               hz=bdup(3,i,k)/Bnorm
               ! Euler
               !v=0.0_dblprec
               ! Heun
               v=Bnorm*delta_t*gama*lldamp
               ! Ralston
               !v=Bnorm*delta_t*gama*lldamp*2.0_dblprec/3.0_dblprec
               ! Midpoint
               !v=Bnorm*delta_t*gama*lldamp*0.5_dblprec
               cosv=cos(v)
               sinv=sin(v)
               u=1.0_dblprec-cosv
               mrod(1,i,k)=hx*hx*u*emom(1,i,k)+cosv*emom(1,i,k)+hx*hy*u*emom(2,i,k)-hz*sinv*emom(2,i,k)+ &
                  hx*hz*u*emom(3,i,k)+hy*sinv*emom(3,i,k)
               mrod(2,i,k)=hy*hx*u*emom(1,i,k)+hz*sinv*emom(1,i,k)+hy*hy*u*emom(2,i,k)+cosv*emom(2,i,k)+ &
                  hy*hz*u*emom(3,i,k)-hx*sinv*emom(3,i,k)
               mrod(3,i,k)=hx*hz*u*emom(1,i,k)-hy*sinv*emom(1,i,k)+hz*hy*u*emom(2,i,k)+hx*sinv*emom(2,i,k)+ &
                  hz*hz*u*emom(3,i,k)+cosv*emom(3,i,k)

               ! copy m(t) to emom2 and m(t+dt) to emom for heisge, save b(t)
               emom2(:,i,k)=emom(:,i,k)
               emomM(:,i,k)=mrod(:,i,k)*mmom(i,k)

               emom(:,i,k)=mrod(:,i,k)

               b2eff(:,i,k)=bdup(:,i,k)
              
            end do
         end do
         !$omp end parallel do
   else
         bdup=0.0_dblprec
         if(stt/='N') then
            stt_fac=1.0_dblprec
            !$omp parallel do default(shared) private(i,ired,k)  schedule(static) collapse(2)
            do k=1,Mensemble
               do ired=1,Nred
                  i=red_atom_list(ired)
                  ! Adding STT and SHE torques if present (prefactor instead of if-statement)
                  bdup(:,i,k)=bdup(:,i,k)+stt_fac*btorque(:,i,k)
               end do
            end do
            !$omp end parallel do
         else
            stt_fac=0.0_dblprec
         end if
!!!!!
         if(do_she/='N') then
            she_fac=1.0_dblprec
            !$omp parallel do default(shared) private(i,ired,k)  schedule(static) collapse(2)
            do k=1,Mensemble
               do ired=1,Nred
                  i=red_atom_list(ired)
                  ! Adding STT and SHE torques if present (prefactor instead of if-statement)
                  bdup(:,i,k)= bdup(:,i,k)+she_fac*she_btorque(:,i,k)
               end do
            end do
            !$omp end parallel do
         else
            she_fac=0.0_dblprec
         end if
         if(do_sot/='N') then
            sot_fac=1.0_dblprec
            !$omp parallel do default(shared) private(i,ired,k)  schedule(static) collapse(2)
            do k=1,Mensemble
               do ired=1,Nred
                  i=red_atom_list(ired)
                  ! Adding STT, SHE and SOT torques if present (prefactor instead of if-statement)
                  bdup(:,i,k)= bdup(:,i,k)+sot_fac*sot_btorque(:,i,k)
               end do
            end do
            !$omp end parallel do
         else
            sot_fac=0.0_dblprec
         end if

         call rng_gaussianP(btherm,3*Natom*Mensemble,1.0_dblprec)

         ! Dupont recipe J. Phys.: Condens. Matter 21 (2009) 336005
         !$omp parallel do default(shared) private(ired,i,k,Dp,sigma,Bnorm,hx,hy,hz,v,lldamp,cosv,sinv,u)  schedule(static) collapse(2)
         do k=1,Mensemble
            do ired=1,Nred
               
               i=red_atom_list(ired)
               ! Thermal field
               !   LL equations ONE universal damping
           
               Dp=(2.0_dblprec*damp_tot_array(1,i,k)*k_bolt)/(delta_t*gama*mub)   !LLG
               sigma=sqrt(Dp*temprescale*Temp_array(i)/mmom(i,k))
               btherm(:,i,k)=btherm(:,i,k)*sigma
              
               ! Construct local field
               bloc(:,i,k)=(beff(:,i,k)+btherm(:,i,k))
               b_eff_tot(:,i,k)=bloc(:,i,k)
               thermal_field(:,i,k)=btherm(:,i,k)
               lldamp=1.0_dblprec/(1.0_dblprec+damp_local(1,1,i,k)**2)

               ! DO I=1,3
               !    Do J=1,3  
               !       AA=0.0_dblprec
               !       DO K=1,3
               !          AA=AA+damp_local(I,K,i,k)*damp_local(K,J,i,k)
               !          lldamp2(I,J)=1.0_dblprec/(AA+1.0_dblprec)
               !       END DO
               !    END DO
               ! END DO
               ! Construct effective field (including damping term)
               bdup(1,i,k)=bdup(1,i,k)+bloc(1,i,k)+bdamp_onsite(1,i,k)+bdamp_offsite(1,i,k)/lldamp
               bdup(2,i,k)=bdup(2,i,k)+bloc(2,i,k)+bdamp_onsite(2,i,k)+bdamp_offsite(2,i,k)/lldamp
               bdup(3,i,k)=bdup(3,i,k)+bloc(3,i,k)+bdamp_onsite(3,i,k)+bdamp_offsite(3,i,k)/lldamp

               ! Set up rotation matrices and perform rotations
              
               
               Bnorm=bdup(1,i,k)**2+bdup(2,i,k)**2+bdup(3,i,k)**2
               Bnorm=sqrt(Bnorm)+1.0d-15
               hx=bdup(1,i,k)/Bnorm
               hy=bdup(2,i,k)/Bnorm
               hz=bdup(3,i,k)/Bnorm
               ! Euler
               !v=0.0_dblprec
               ! Heun
               v=Bnorm*delta_t*gama*lldamp
               ! Ralston
               !v=Bnorm*delta_t*gama*lldamp*2.0_dblprec/3.0_dblprec
               ! Midpoint
               !v=Bnorm*delta_t*gama*lldamp*0.5_dblprec
               cosv=cos(v)
               sinv=sin(v)
               u=1.0_dblprec-cosv
               mrod(1,i,k)=hx*hx*u*emom(1,i,k)+cosv*emom(1,i,k)+hx*hy*u*emom(2,i,k)-hz*sinv*emom(2,i,k)+ &
                  hx*hz*u*emom(3,i,k)+hy*sinv*emom(3,i,k)
               mrod(2,i,k)=hy*hx*u*emom(1,i,k)+hz*sinv*emom(1,i,k)+hy*hy*u*emom(2,i,k)+cosv*emom(2,i,k)+ &
                  hy*hz*u*emom(3,i,k)-hx*sinv*emom(3,i,k)
               mrod(3,i,k)=hx*hz*u*emom(1,i,k)-hy*sinv*emom(1,i,k)+hz*hy*u*emom(2,i,k)+hx*sinv*emom(2,i,k)+ &
                  hz*hz*u*emom(3,i,k)+cosv*emom(3,i,k)

               ! copy m(t) to emom2 and m(t+dt) to emom for heisge, save b(t)
               emom2(:,i,k)=emom(:,i,k)
               emomM2(:,i,k)=emom2(:,i,k)*mmom(i,k)
               emomM(:,i,k)=mrod(:,i,k)*mmom(i,k)

               emom(:,i,k)=mrod(:,i,k)

               b2eff(:,i,k)=bdup(:,i,k)
             
            end do
         end do
         !$omp end parallel do
      end if
   end subroutine depondt_evolve_first

   !-----------------------------------------------------------------------------
   !  SUBROUTINE: depondt_evolve_second
   !> @brief
   !> Second step of Depond solver, calculates the corrected effective field from
   !> the predicted effective fields. Rotates the moments in the corrected field
   !
   !> @author Anders Bergman
   !-----------------------------------------------------------------------------
   subroutine depondt_evolve_second(b_eff_tot,damp_local,bdamp_onsite,bdamp_offsite,mmom,emomM,emomM2,damp_tot_array,do_damptensor,Natom,Nred, &
      Mensemble,lambda1_array,beff,b2eff, btorque, emom, emom2, delta_t, stt,do_she,she_btorque,do_sot,sot_btorque,  &
         red_atom_list)

      use Constants, only : gama
      !
      implicit none
      !
      integer, intent(in) :: Nred   !< Number of atoms that evolve
      integer, intent(in) :: Natom  !< Number of atoms in system
      integer, intent(in) :: Mensemble !< Number of ensembles
      real(dblprec), intent(in) :: delta_t !< Time step
      character(len=1), intent(in) :: STT    !< Treat spin transfer torque?
      character(len=1), intent(in) :: do_she !< Treat the SHE spin transfer torque
      character(len=1), intent(in) :: do_sot !< Treat the general SOT model
      integer, dimension(Nred), intent(in) :: red_atom_list !< List of indices of atoms that evolve
      real(dblprec), dimension(Natom), intent(in) :: lambda1_array !< Damping parameter
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: beff !< Total effective field from application of Hamiltonian
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: bdamp_onsite,bdamp_offsite     !< damping field(damping tensor form)
      real(dblprec), dimension(3,3,Natom,Mensemble), intent(in) :: damp_local    !local damping tensor
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: b2eff !< Temporary storage of magnetic field
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: btorque !< Spin transfer torque
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: she_btorque !< SHE spin transfer torque
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: sot_btorque !< Spin orbit torque
      real(dblprec), dimension(3,Natom,Mensemble), intent(out) :: emom   !< Current unit moment vector
      real(dblprec), dimension(3,Natom,Mensemble), intent(out) :: emom2  !< Final (or temporary) unit moment vector
      real(dblprec), dimension(Natom,Mensemble), intent(in) :: mmom !< Magnitude of magnetic moments
      real(dblprec), dimension(3,Natom,Mensemble), intent(out) :: emomM !< Current magnetic moment vector
      real(dblprec), dimension(3,Natom,Mensemble), intent(out) :: emomM2 !< t-1 magnetic moment vector
      real(dblprec), dimension(3,Natom,Mensemble), intent(out) :: b_eff_tot ! beff+btherm
      real(dblprec), dimension(1,Natom,Mensemble), intent(in) :: damp_tot_array !< site total damping 
      integer, intent(in) :: do_damptensor       !< flag do damping tensor
      !
      integer :: i,k,ired
      real(dblprec) :: v,Bnorm,hx,hy,hz
      real(dblprec) :: u,cosv,sinv,lldamp, she_fac, stt_fac,sot_fac
      
      if(do_damptensor/=1) then
         if(stt/='N') then
            stt_fac=1.0_dblprec
         else
            stt_fac=0.0_dblprec
         end if

         if(do_she/='N') then
            she_fac=1.0_dblprec
         else
            she_fac=0.0_dblprec
         end if
         if(do_sot/='N') then
            sot_fac=1.0_dblprec
         else
            sot_fac=0.0_dblprec
         end if

         bdup(:,:,:)=0.0_dblprec
         if(stt=='Y') then
            !$omp parallel do default(shared) private(i,ired,k)  schedule(static) collapse(2)
            do k=1,Mensemble
               do ired=1,Natom
                  i=red_atom_list(ired)
                  ! Adding STT and SHE torques if present (prefactor instead of if-statement)
                  bdup(:,i,k)=bdup(:,i,k)+stt_fac*btorque(:,i,k)+she_fac*she_btorque(:,i,k)
               end do
            end do
            !$omp end parallel do
         endif
         if (do_sot=='Y') then
            !$omp parallel do default(shared) private(i,ired,k)  schedule(static) collapse(2)
            do k=1,Mensemble
               do ired=1,Nred
                  i=red_atom_list(ired)
                  ! Adding STT and SHE torques if present (prefactor instead of if-statement)
                  bdup(:,i,k)=bdup(:,i,k)+sot_fac*sot_btorque(:,i,k)
               end do
            end do
            !$omp end parallel do
         endif
         if (do_she=='Y') then
            !$omp parallel do default(shared) private(i,ired,k)  schedule(static) collapse(2)
            do k=1,Mensemble
               do ired=1,Nred
                  i=red_atom_list(ired)
                  ! Adding STT and SHE torques if present (prefactor instead of if-statement)
                  bdup(:,i,k)=bdup(:,i,k)+she_fac*she_btorque(:,i,k)
               end do
            end do
            !$omp end parallel do
         endif

         !$omp parallel do default(shared) private(ired,i,k,Bnorm,hx,hy,hz,v,lldamp,cosv,sinv,u) schedule(static) collapse(2)
         do k=1,Mensemble
            do ired=1,Nred

               i=red_atom_list(ired)
               ! Construct local field
               bloc(:,i,k)=beff(:,i,k)+btherm(:,i,k)
               ! Construct effective field (including damping term)
               bdup(1,i,k)=bdup(1,i,k)+bloc(1,i,k)+lambda1_array(i)*emom(2,i,k)*bloc(3,i,k)-lambda1_array(i)*emom(3,i,k)*bloc(2,i,k)
               bdup(2,i,k)=bdup(2,i,k)+bloc(2,i,k)+lambda1_array(i)*emom(3,i,k)*bloc(1,i,k)-lambda1_array(i)*emom(1,i,k)*bloc(3,i,k)
               bdup(3,i,k)=bdup(3,i,k)+bloc(3,i,k)+lambda1_array(i)*emom(1,i,k)*bloc(2,i,k)-lambda1_array(i)*emom(2,i,k)*bloc(1,i,k)
               
               ! Corrected field
               ! Euler
               !bdup(:,i,k)=0.00_dblprec*bdup(:,i,k)+1.00_dblprec*b2eff(:,i,k)
               ! Heun
               bdup(:,i,k)=0.50_dblprec*bdup(:,i,k)+0.50_dblprec*b2eff(:,i,k)
               
               ! Ralston
               !bdup(:,i,k)=0.75_dblprec*bdup(:,i,k)+0.25_dblprec*b2eff(:,i,k)
               ! Midpoint
               !bdup(:,i,k)=1.00_dblprec*bdup(:,i,k)+0.00_dblprec*b2eff(:,i,k)
               !
               emom(:,i,k)=emom2(:,i,k)

               ! Set up rotation matrices and perform rotations
               lldamp=1.0_dblprec/(1.0_dblprec+lambda1_array(i)**2)
               Bnorm=bdup(1,i,k)**2+bdup(2,i,k)**2+bdup(3,i,k)**2
               Bnorm=sqrt(Bnorm)+1.0d-15
               hx=bdup(1,i,k)/Bnorm
               hy=bdup(2,i,k)/Bnorm
               hz=bdup(3,i,k)/Bnorm
               v=Bnorm*delta_t*gama*lldamp
               cosv=cos(v)
               sinv=sin(v)
               u=1.0_dblprec-cosv
               mrod(1,i,k)=hx*hx*u*emom(1,i,k)+cosv*emom(1,i,k)+hx*hy*u*emom(2,i,k)-hz*sinv*emom(2,i,k)+ &
                  hx*hz*u*emom(3,i,k)+hy*sinv*emom(3,i,k)
               mrod(2,i,k)=hy*hx*u*emom(1,i,k)+hz*sinv*emom(1,i,k)+hy*hy*u*emom(2,i,k)+cosv*emom(2,i,k)+ &
                  hy*hz*u*emom(3,i,k)-hx*sinv*emom(3,i,k)
               mrod(3,i,k)=hx*hz*u*emom(1,i,k)-hy*sinv*emom(1,i,k)+hz*hy*u*emom(2,i,k)+hx*sinv*emom(2,i,k)+ &
                  hz*hz*u*emom(3,i,k)+cosv*emom(3,i,k)

               ! Final update
               emom2(:,i,k)=mrod(:,i,k)
            end do
         end do
         !$omp end parallel do
      else
         if(stt/='N') then
            stt_fac=1.0_dblprec
         else
            stt_fac=0.0_dblprec
         end if

         if(do_she/='N') then
            she_fac=1.0_dblprec
         else
            she_fac=0.0_dblprec
         end if
         if(do_sot/='N') then
            sot_fac=1.0_dblprec
         else
            sot_fac=0.0_dblprec
         end if

         bdup(:,:,:)=0.0_dblprec
         if(stt=='Y') then
            !$omp parallel do default(shared) private(i,ired,k)  schedule(static) collapse(2)
            do k=1,Mensemble
               do ired=1,Natom
                  i=red_atom_list(ired)
                  ! Adding STT and SHE torques if present (prefactor instead of if-statement)
                  bdup(:,i,k)=bdup(:,i,k)+stt_fac*btorque(:,i,k)+she_fac*she_btorque(:,i,k)
               end do
            end do
            !$omp end parallel do
         endif
         if (do_sot=='Y') then
            !$omp parallel do default(shared) private(i,ired,k)  schedule(static) collapse(2)
            do k=1,Mensemble
               do ired=1,Nred
                  i=red_atom_list(ired)
                  ! Adding STT and SHE torques if present (prefactor instead of if-statement)
                  bdup(:,i,k)=bdup(:,i,k)+sot_fac*sot_btorque(:,i,k)
               end do
            end do
            !$omp end parallel do
         endif
         if (do_she=='Y') then
            !$omp parallel do default(shared) private(i,ired,k)  schedule(static) collapse(2)
            do k=1,Mensemble
               do ired=1,Nred
                  i=red_atom_list(ired)
                  ! Adding STT and SHE torques if present (prefactor instead of if-statement)
                  bdup(:,i,k)=bdup(:,i,k)+she_fac*she_btorque(:,i,k)
               end do
            end do
            !$omp end parallel do
         endif

         !$omp parallel do default(shared) private(ired,i,k,Bnorm,hx,hy,hz,v,lldamp,cosv,sinv,u) schedule(static) collapse(2)
         do k=1,Mensemble
            do ired=1,Nred

               i=red_atom_list(ired)
               ! Construct local field
               bloc(:,i,k)=beff(:,i,k)+btherm(:,i,k)
               b_eff_tot(:,i,k)=bloc(:,i,k)
               lldamp=1.0_dblprec/(1.0_dblprec+damp_local(1,1,i,k)**2)
               ! Construct effective field (including damping term)
               bdup(1,i,k)=bdup(1,i,k)+bloc(1,i,k)+bdamp_onsite(1,i,k)+bdamp_offsite(1,i,k)/lldamp
               bdup(2,i,k)=bdup(2,i,k)+bloc(2,i,k)+bdamp_onsite(2,i,k)+bdamp_offsite(2,i,k)/lldamp
               bdup(3,i,k)=bdup(3,i,k)+bloc(3,i,k)+bdamp_onsite(3,i,k)+bdamp_offsite(3,i,k)/lldamp
               
               ! Corrected field
               ! Euler
               !bdup(:,i,k)=0.00_dblprec*bdup(:,i,k)+1.00_dblprec*b2eff(:,i,k)
               ! Heun
               bdup(:,i,k)=0.50_dblprec*bdup(:,i,k)+0.50_dblprec*b2eff(:,i,k)
              
               ! Ralston
               !bdup(:,i,k)=0.75_dblprec*bdup(:,i,k)+0.25_dblprec*b2eff(:,i,k)
               ! Midpoint
               !bdup(:,i,k)=1.00_dblprec*bdup(:,i,k)+0.00_dblprec*b2eff(:,i,k)
               !
               emom(:,i,k)=emom2(:,i,k)

               ! Set up rotation matrices and perform rotations
               
               Bnorm=bdup(1,i,k)**2+bdup(2,i,k)**2+bdup(3,i,k)**2
               Bnorm=sqrt(Bnorm)+1.0d-15
               hx=bdup(1,i,k)/Bnorm
               hy=bdup(2,i,k)/Bnorm
               hz=bdup(3,i,k)/Bnorm
               v=Bnorm*delta_t*gama*lldamp
               cosv=cos(v)
               sinv=sin(v)
               u=1.0_dblprec-cosv
               mrod(1,i,k)=hx*hx*u*emom(1,i,k)+cosv*emom(1,i,k)+hx*hy*u*emom(2,i,k)-hz*sinv*emom(2,i,k)+ &
                  hx*hz*u*emom(3,i,k)+hy*sinv*emom(3,i,k)
               mrod(2,i,k)=hy*hx*u*emom(1,i,k)+hz*sinv*emom(1,i,k)+hy*hy*u*emom(2,i,k)+cosv*emom(2,i,k)+ &
                  hy*hz*u*emom(3,i,k)-hx*sinv*emom(3,i,k)
               mrod(3,i,k)=hx*hz*u*emom(1,i,k)-hy*sinv*emom(1,i,k)+hz*hy*u*emom(2,i,k)+hx*sinv*emom(2,i,k)+ &
                  hz*hz*u*emom(3,i,k)+cosv*emom(3,i,k)

               ! Final update
               emom2(:,i,k)=mrod(:,i,k)
               emomM2(:,i,k)=emom(:,i,k)*mmom(i,k)
               emomM(:,i,k)=emom2(:,i,k)*mmom(i,k)
            end do
         end do
         !$omp end parallel do
      end if

   end subroutine depondt_evolve_second



   !-----------------------------------------------------------------------------
   !  SUBROUTINE: rodmat
   !> @brief
   !> Creates a rotation matrix for Rodrigues rotations
   !> for rotation around unit vector kvec with angle angle.
   !> Uses the Euler-Rodrigues notation.
   !
   !> @note
   !> Assumes that rotation axis vector kvec is normalized
   !
   !> @author Anders Bergman
   !-----------------------------------------------------------------------------
   subroutine rodmat(kvec,angle,R)
      !
      !
      implicit none

      real(dblprec), dimension(3), intent(in) :: kvec  !< Vector to rotate around (normalized)
      real(dblprec), intent(in) :: angle !< Rotation angle in radians
      real(dblprec), dimension(3,3), intent(out) :: R !< Output rotation matrix


      real(dblprec) :: a,b,c,d


      a=cos(angle*0.5_dblprec)
      b=kvec(1)*sin(angle*0.5_dblprec)
      c=kvec(2)*sin(angle*0.5_dblprec)
      d=kvec(3)*sin(angle*0.5_dblprec)

      R(1,1)=a*a+b*b-c*c-d*d
      R(1,2)=2.0_dblprec*(b*c+a*d)
      R(1,3)=2.0_dblprec*(b*d-a*c)
      R(2,1)=2.0_dblprec*(b*c-a*d)
      R(2,2)=a*a-b*b+c*c-d*d
      R(2,3)=2.0_dblprec*(c*d+a*b)
      R(3,1)=2.0_dblprec*(b*d+a*c)
      R(3,2)=2.0_dblprec*(c*d-a*b)
      R(3,3)=a*a-b*b-c*c+d*d


   end subroutine rodmat

   !-----------------------------------------------------------------------------
   !  SUBROUTINE: locmat
   !> @brief
   !> Creates the Rodrigues rotation matrix that rotates vector mvec to vector nvec
   !> using the Euler-Rodrigues notation
   !
   !> @note
   !> Assumes that the vectors mvec and nvec are normalized
   !
   !> @author Anders Bergman
   !-----------------------------------------------------------------------------
   subroutine locmat(mvec,nvec,R)
      !
      !
      implicit none

      real(dblprec), dimension(3), intent(in) :: mvec  !< Vector to rotate from  (normalized)
      real(dblprec), dimension(3), intent(in) :: nvec  !< Vector to rotate to  (normalized)
      real(dblprec), dimension(3,3), intent(out) :: R !< Output rotation matrix


      real(dblprec),dimension(3) :: crossvec
      real(dblprec) :: dotp, angle
      !R_t=rodmat(z,cross(z,mi),acos(dot(z,mi))/norm(cross(mi,z)));

      crossvec(1)=mvec(2)*nvec(3)-mvec(3)*nvec(2)
      crossvec(2)=mvec(3)*nvec(1)-mvec(1)*nvec(3)
      crossvec(3)=mvec(1)*nvec(2)-mvec(2)*nvec(1)

      dotp=mvec(1)*nvec(1)+mvec(2)*nvec(2)+mvec(3)*nvec(3)
      angle=acos(dotp)

      call rodmat(crossvec,angle,R)

   end subroutine locmat

   !-----------------------------------------------------------------------------
   !  SUBROUTINE: invmat
   !> @brief
   !> Simple inversion of a 3x3 matrix
   !
   !> @author Anders Bergman
   !-----------------------------------------------------------------------------
   subroutine invmat(R,R_inv)
      !
      !
      implicit none

      real(dblprec), dimension(3,3), intent(in) :: R !< Input matrix
      real(dblprec), dimension(3,3), intent(out):: R_inv !< Output inverse matrix

      real(dblprec) :: det, invdet
      real(dblprec), dimension(3,3) :: cofactt !< transpose of cofactor


      det= R(1,1)*R(2,2)*R(3,3) &
          -R(1,1)*R(2,3)*R(3,2) &
          -R(1,2)*R(2,1)*R(3,3) &
          +R(1,2)*R(2,3)*R(3,1) &
          +R(1,3)*R(2,1)*R(3,2) &
          -R(1,3)*R(2,2)*R(3,1)

      if(det==0.0_dblprec) then
         R_inv=R
      else
         invdet=1.0_dblprec*det

         cofactt(1,1)= (R(2,2)*R(3,3)-R(2,3)*R(3,2))
         cofactt(2,1)=-(R(2,1)*R(3,3)-R(2,3)*R(3,1))
         cofactt(3,1)= (R(2,1)*R(3,2)-R(2,2)*R(3,1))
         cofactt(1,2)=-(R(1,2)*R(3,3)-R(1,3)*R(3,2))
         cofactt(2,2)= (R(1,1)*R(3,3)-R(1,3)*R(3,1))
         cofactt(3,2)=-(R(1,1)*R(3,2)-R(1,2)*R(3,1))
         cofactt(1,3)= (R(1,2)*R(2,3)-R(1,3)*R(2,2))
         cofactt(2,3)=-(R(1,1)*R(2,3)-R(1,3)*R(2,1))
         cofactt(3,3)= (R(1,1)*R(2,2)-R(1,2)*R(2,1))

         R_inv=invdet*cofactt

      end if

      return

   end subroutine invmat

   !-----------------------------------------------------------------------------
   !  SUBROUTINE: rodrigues
   !> @brief
   !> Performs a Rodrigues rotation of the magnetic moments
   !> in the effective field.
   !
   !> @author Anders Bergman
   !-----------------------------------------------------------------------------
   subroutine rodrigues(Natom, Mensemble,emom, delta_t,lambda1_array)
      !
      use Constants, only : gama
      !
      implicit none

      integer, intent(in) :: Natom !< Number of atoms in system
      integer, intent(in) :: Mensemble !< Number of ensembles
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: emom   !< Current unit moment vector
      real(dblprec), intent(in) :: delta_t !< Time step
      real(dblprec), dimension(Natom), intent(in) :: lambda1_array !< Damping parameter
      real(dblprec) :: v,Bnorm,hx,hy,hz
      real(dblprec) :: u,cosv,sinv,lldamp

      integer :: ik,i,k

      !$omp parallel do default(shared) private(ik,i,k,Bnorm,hx,hy,hz,v,lldamp,cosv,sinv,u) schedule(static) collapse(2)
      do k=1,Mensemble
         do i=1,Natom
            lldamp=1.0_dblprec/(1.0_dblprec+lambda1_array(i)**2)
            Bnorm=bdup(1,i,k)**2+bdup(2,i,k)**2+bdup(3,i,k)**2
            Bnorm=sqrt(Bnorm)
            hx=bdup(1,i,k)/Bnorm
            hy=bdup(2,i,k)/Bnorm
            hz=bdup(3,i,k)/Bnorm
            v=Bnorm*delta_t*gama*lldamp
            cosv=cos(v)
            sinv=sin(v)
            u=1.0_dblprec-cosv
            mrod(1,i,k)=hx*hx*u*emom(1,i,k)+cosv*emom(1,i,k)+hx*hy*u*emom(2,i,k)-hz*sinv*emom(2,i,k)+ &
               hx*hz*u*emom(3,i,k)+hy*sinv*emom(3,i,k)
            mrod(2,i,k)=hy*hx*u*emom(1,i,k)+hz*sinv*emom(1,i,k)+hy*hy*u*emom(2,i,k)+cosv*emom(2,i,k)+ &
               hy*hz*u*emom(3,i,k)-hx*sinv*emom(3,i,k)
            mrod(3,i,k)=hx*hz*u*emom(1,i,k)-hy*sinv*emom(1,i,k)+hz*hy*u*emom(2,i,k)+hx*sinv*emom(2,i,k)+ &
               hz*hz*u*emom(3,i,k)+cosv*emom(3,i,k)
         end do
      end do
      !$omp end parallel do

   end subroutine rodrigues

   !-----------------------------------------------------------------------------
   !  SUBROUTINE: thermfield
   !> @brief
   !> Calculates stochastic field
   !
   !> @author Anders Bergman
   !-----------------------------------------------------------------------------
   subroutine thermfield(Natom, Mensemble, lambda1_array, mmom, deltat,Temp_array,temprescale)
      !
      use Constants, only : k_bolt, gama, mub
      use RandomNumbers, only : rng_gaussian

      implicit none

      integer, intent(in) :: Natom !< Number of atoms in system
      integer, intent(in) :: Mensemble !< Number of ensembles
      real(dblprec), dimension(Natom), intent(in) :: lambda1_array !< Damping parameter
      real(dblprec), dimension(Natom,Mensemble), intent(in) :: mmom !< Magnitude of magnetic moments
      real(dblprec), intent(in) :: deltat !< Time step
      real(dblprec), dimension(Natom), intent(in) :: Temp_array  !< Temperature (array)
      real(dblprec), intent(in) :: temprescale  !< Temperature rescaling from QHB

      real(dblprec), dimension(Natom) :: Dp
      real(dblprec) :: mu, sigma

      integer :: i,k

      !   LL equations ONE universal damping
      Dp=(2.0_dblprec*lambda1_array*k_bolt)/(deltat*gama*mub)   !LLG

      !   LLG equations ONE universal damping
      call rng_gaussian(btherm,3*Natom*Mensemble,1.0_dblprec)
      mu=0.0_dblprec

      !$omp parallel do default(shared) private(k,i,sigma) collapse(2) schedule(static)
      do k=1, Mensemble
         do i=1, Natom
            sigma=sqrt(Dp(i)*temprescale*Temp_array(i)/mmom(i,k))
            btherm(:,i,k)=btherm(:,i,k)*sigma
         end do
      end do
      !$omp end parallel do

   end subroutine thermfield

   !-----------------------------------------------------------------------------
   !  SUBROUTINE: buildbeff
   !> @brief
   !> Constructs the effective field (including damping term)
   !
   !> @author Anders Bergman
   !-----------------------------------------------------------------------------
   subroutine buildbeff(Natom, Mensemble,lambda1_array,emom, btorque, stt,do_she,she_btorque,&
      do_sot,sot_btorque)

      implicit none
      !
      integer, intent(in) :: Natom !< Number of atoms in system
      integer, intent(in) :: Mensemble !< Number of ensembles
      real(dblprec), dimension(Natom), intent(in) :: lambda1_array !< Damping parameter
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: emom   !< Current unit moment vector
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: btorque !< Spin transfer torque
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: she_btorque !< SHE spin transfer torque
      real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: sot_btorque !< Spin orbit torque
      character(len=1), intent(in) :: STT !< Treat spin transfer torque?
      character(len=1), intent(in) :: do_she !< Treat SHE spin transfer torque
      character(len=1), intent(in) :: do_sot !< Treat the general SOT model
      !
      integer :: i,k

      !$omp parallel do default(shared) private(i,k) schedule(static) collapse(2)
      do k=1,Mensemble
         do i=1,Natom
            bdup(1,i,k)=bloc(1,i,k)+lambda1_array(i)*emom(2,i,k)*bloc(3,i,k)-lambda1_array(i)*emom(3,i,k)*bloc(2,i,k)
            bdup(2,i,k)=bloc(2,i,k)+lambda1_array(i)*emom(3,i,k)*bloc(1,i,k)-lambda1_array(i)*emom(1,i,k)*bloc(3,i,k)
            bdup(3,i,k)=bloc(3,i,k)+lambda1_array(i)*emom(1,i,k)*bloc(2,i,k)-lambda1_array(i)*emom(2,i,k)*bloc(1,i,k)
         end do
      end do
      !$omp end parallel do

      if(stt/='N') then
         !$omp parallel do default(shared) private(i,k) schedule(static) collapse(2)
         do k=1,Mensemble
            do i=1,Natom
               bdup(:,i,k)=bdup(:,i,k)+btorque(:,i,k)
            end do
         end do
         !$omp end parallel do
      endif

      if(do_she/='N') then
         !$omp parallel do default(shared) private(i,k) schedule(static) collapse(2)
         do k=1,Mensemble
            do i=1,Natom
               bdup(:,i,k)=bdup(:,i,k)+she_btorque(:,i,k)
            end do
         end do
         !$omp end parallel do

      end if
      if(do_sot/='N') then
         !$omp parallel do default(shared) private(i,k) schedule(static) collapse(2)
         do k=1,Mensemble
            do i=1,Natom
               bdup(:,i,k)=bdup(:,i,k)+sot_btorque(:,i,k)
            end do
         end do
         !$omp end parallel do

      end if

   end subroutine buildbeff

   !-----------------------------------------------------------------------------
   !  SUBROUTINE: allocate_depondtfields
   !> @brief
   !> Allocates work arrays for the Depondt solver
   !
   !> @author Anders Bergman
   !-----------------------------------------------------------------------------
   subroutine allocate_depondtfields(Natom,Mensemble,flag)

      implicit none

      integer, intent(in) :: Natom !< Number of atoms in system
      integer, intent(in) :: Mensemble !< Number of ensembles
      integer, intent(in) :: flag !< Allocate or deallocate (1/-1)

      integer :: i_all, i_stat

      if(flag>0) then
         allocate(bloc(3,Natom,Mensemble),stat=i_stat)
         call memocc(i_stat,product(shape(bloc))*kind(bloc),'bloc','allocate_depondtfields')
         bloc=0.0_dblprec
         allocate(btherm(3,Natom,Mensemble),stat=i_stat)
         call memocc(i_stat,product(shape(btherm))*kind(btherm),'btherm','allocate_depondtfields')
         btherm=0.0_dblprec
         allocate(b_eff_tot(3,Natom,Mensemble),stat=i_stat)
         call memocc(i_stat,product(shape(b_eff_tot))*kind(b_eff_tot),'b_eff_tot','allocate_depondtfields')
         b_eff_tot=0.0_dblprec
         allocate(bdup(3,Natom,Mensemble),stat=i_stat)
         call memocc(i_stat,product(shape(bdup))*kind(bdup),'bdup','allocate_depondtfields')
         bdup=0.0_dblprec
         allocate(mrod(3,Natom,Mensemble),stat=i_stat)
         call memocc(i_stat,product(shape(mrod))*kind(mrod),'mrod','allocate_depondtfields')
         mrod=0.0_dblprec
      else
         i_all=-product(shape(bloc))*kind(bloc)
         deallocate(bloc,stat=i_stat)
         call memocc(i_stat,i_all,'bloc','allocate_systemdata')
         i_all=-product(shape(btherm))*kind(btherm)
         deallocate(btherm,stat=i_stat)
         call memocc(i_stat,i_all,'btherm','allocate_systemdata')
         i_all=-product(shape(b_eff_tot))*kind(b_eff_tot)
         deallocate(b_eff_tot,stat=i_stat)
         call memocc(i_stat,i_all,'b_eff_tot','allocate_systemdata')
         i_all=-product(shape(bdup))*kind(bdup)
         deallocate(bdup,stat=i_stat)
         call memocc(i_stat,i_all,'bdup','allocate_systemdata')
         i_all=-product(shape(mrod))*kind(mrod)
         deallocate(mrod,stat=i_stat)
         call memocc(i_stat,i_all,'mrod','allocate_systemdata')
      end if
   end subroutine allocate_depondtfields


end module depondt



module damping_field

    use Profiling
    use Parameters
    use HamiltonianData
    use InputData, only : ham_inp
 
    implicit none
 
 contains
 
    !----------------------------------------------------------------------------
    ! SUBROUTINE: effective_field
    !> @brief
    !> Calculate effective field by applying the derivative of the Hamiltonian
    !> @author Anders Bergman, Lars Bergqvist, Johan Hellsvik
    !> @todo Check consistency of terms wrt the input parameters, especially the anisotropies
    !> @todo Replace moment unit vectors emom with full length vectors emomM
    !ham%dm_vect !< DM vector \f$H_{DM}=\sum{D_{ij}\dot(m_i \times m_j)}\f$
    !> @todo Check the sign of the dipolar field
    !----------------------------------------------------------------------------
 
 subroutine damp_field(i, k, beff,field_onsite,field_offsite,Natom,Mensemble,emomM,emomM2,delta_t,damp_tot,damp_onsite)
    
   use Constants, only : gama
   use MomentData, only: mmom
   implicit none
   real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: beff ! b_eff+b_therm
   integer, intent(in) :: i !< Atom to calculate effective field for
   integer, intent(in) :: k !< Current ensemble
   integer, intent(in) :: Natom        !< Number of atoms in system
   integer, intent(in) :: Mensemble    !< Number of ensembles
   real(dblprec), dimension(3), intent(inout) :: field_onsite!< onsite damping field
   real(dblprec), dimension(3), intent(inout) :: field_offsite!< offsite damping field
   real(dblprec), dimension(3,3) ,intent(out) :: damp_onsite
   real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: emomM  !< Current magnetic moment vector
   real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: emomM2  !< t-1 magnetic moment vector
   real(dblprec), intent(in) :: delta_t   !< Time step
   real(dblprec), intent(out) :: damp_tot   !< site total damping

   !

   integer :: j ! Neighbourlist index
   integer :: x ! Exchange index
   integer :: ih ! Hamiltonian index

   !Exchange term
   ih=ham%damp_table(i)

#if _OPENMP >= 201307 && ( ! defined __INTEL_COMPILER_BUILD_DATE || __INTEL_COMPILER_BUILD_DATE > 20140422) && __INTEL_COMPILER < 1800
!        !$omp simd reduction(+:field_onsite,field_offsite)         
#endif
   do j=1,ham%damp_nlistsize(ih)
      x = ham%damp_nlist(j,i);
      if(x==i) then
         damp_tot=0.0_dblprec
         field_onsite=0.0_dblprec
         damp_tot=(ham%damp_tens(1,1,j,i)+ham%damp_tens(2,2,j,i)+ham%damp_tens(3,3,j,i))/3
         damp_onsite=ham%damp_tens(:,:,j,i)
         field_onsite(1)=field_onsite(1)+(ham%damp_tens(1,1,j,i)*emomM2(2,x,k)*beff(3,x,k)-ham%damp_tens(1,1,j,i)*emomM2(3,x,k)*beff(2,x,k))/mmom(x,k)
         field_onsite(2)=field_onsite(2)+(ham%damp_tens(1,1,j,i)*emomM2(3,x,k)*beff(1,x,k)-ham%damp_tens(1,1,j,i)*emomM2(1,x,k)*beff(3,x,k))/mmom(x,k)
         field_onsite(3)=field_onsite(3)+(ham%damp_tens(1,1,j,i)*emomM2(1,x,k)*beff(2,x,k)-ham%damp_tens(1,1,j,i)*emomM2(2,x,k)*beff(1,x,k))/mmom(x,k)
         
      else
         field_offsite=0.0_dblprec
         field_offsite(1)=field_offsite(1)+(ham%damp_tens(1,1,j,i)*emomM2(2,x,k)*beff(3,x,k)-ham%damp_tens(1,1,j,i)*emomM2(3,x,k)*beff(2,x,k))/mmom(x,k)
         field_offsite(2)=field_offsite(2)+(ham%damp_tens(1,1,j,i)*emomM2(3,x,k)*beff(1,x,k)-ham%damp_tens(1,1,j,i)*emomM2(1,x,k)*beff(3,x,k))/mmom(x,k)
         field_offsite(3)=field_offsite(3)+(ham%damp_tens(1,1,j,i)*emomM2(1,x,k)*beff(2,x,k)-ham%damp_tens(1,1,j,i)*emomM2(2,x,k)*beff(1,x,k))/mmom(x,k)
      end if
      
      
   end do
   
end subroutine damp_field

subroutine damp_tensor_field(beff,delta_t,mmom,emomM2,damp_tot_array,Natom,Mensemble,start_atom,stop_atom,   &
   emomM,bdamp_onsite,bdamp_offsite,damp_local)
   !
   use DipoleManager, only : dipole_field_calculation
   !.. Implicit declarations
   implicit none
   real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: beff !b_eff+b_therm
   real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: emomM2  !< t-1 magnetic moment vector
   real(dblprec), dimension(1,Natom,Mensemble), intent(out) :: damp_tot_array !< site total damping
   real(dblprec), dimension(3,3) :: damp_onsite
   real(dblprec), intent(in) :: delta_t   !< Time step
   integer, intent(in) :: Natom        !< Number of atoms in system
   integer, intent(in) :: Mensemble    !< Number of ensembles
   integer, intent(in) :: start_atom   !< Atom to start loop for
   integer, intent(in) :: stop_atom    !< Atom to end loop for
   real(dblprec), dimension(3,Natom,Mensemble), intent(in) :: emomM  !< Current magnetic moment vector
   real(dblprec), dimension(Natom,Mensemble), intent(in) :: mmom     !< Current magnetic moment
   ! .. Output Variables
   real(dblprec), dimension(3,Natom,Mensemble), intent(out) :: bdamp_onsite,bdamp_offsite  !< Total effective field from application of Hamiltonian
   real(dblprec), dimension(3,3,Natom,Mensemble), intent(out) :: damp_local
      !.. Local scalars
   integer :: i,k
   real(dblprec), dimension(3) ::  beff_s_onsite,beff_s_offsite
   real(dblprec) :: damp_tot   !< site total damping
   ! Initialization if the effective field
   bdamp_onsite=0.0_dblprec
   bdamp_offsite=0.0_dblprec
   damp_tot_array=0.0_dblprec
   
   
   !$omp parallel do default(shared) schedule(static) private(i,k,damp_tot,beff_s_onsite,beff_s_offsite) collapse(2) 
   do k=1, Mensemble
      do i=start_atom, stop_atom
         beff_s_onsite=0.0_dblprec
         call damp_field(i, k,beff, beff_s_onsite,beff_s_offsite,Natom,Mensemble,emomM,emomM2,delta_t,damp_tot,damp_onsite)
         damp_tot_array(1,i,k)= damp_tot_array(1,i,k)+damp_tot
         bdamp_onsite(1:3,i,k) = bdamp_onsite(1:3,i,k)+ beff_s_onsite
         bdamp_offsite(1:3,i,k) = bdamp_offsite(1:3,i,k) + beff_s_offsite
         damp_local(:,:,i,k)=damp_onsite
      end do
   end do
   !$omp end parallel do
   
end subroutine damp_tensor_field
 

end module damping_field
