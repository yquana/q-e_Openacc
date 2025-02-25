!
! Copyright (C) 2001-2016 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
!----------------------------------------------------------------------
subroutine dvqpsi_us (ik, uact, addnlcc, becp1, alphap)
  !----------------------------------------------------------------------
  !! This routine calculates \(dV_\text{bare}/d\tau \cdot \psi\) for one 
  !! perturbation with a given q. The displacements are described by a 
  !! vector u.  
  !! The result is stored in \(\text{dvpsi}\). The routine is called for
  !! each k-point and for each pattern u. It computes simultaneously all 
  !! the bands. It implements Eq. (B29) of PRB 64, 235118 (2001). The 
  !! contribution of the local pseudopotential is calculated here, that 
  !! of the nonlocal pseudopotential in \(\texttt{dvqpsi_us_only}\).
  !
  !
  USE kinds, only : DP
  USE funct,     ONLY : dft_is_nonlocc
  USE xc_lib,    ONLY : xclib_dft_is
  USE ions_base, ONLY : nat, ityp
  USE cell_base, ONLY : tpiba
  USE fft_base,  ONLY : dfftp, dffts
  USE fft_interfaces, ONLY: fwfft, invfft
  USE gvect,     ONLY : eigts1, eigts2, eigts3, mill, g, &
                        ngm
  USE gvecs,     ONLY : ngms, doublegrid
  USE lsda_mod,  ONLY : nspin, lsda, isk
  USE scf,       ONLY : rho, rho_core
  USE noncollin_module, ONLY : nspin_gga, npol
  use uspp_param,ONLY : upf
  USE wvfct,     ONLY : nbnd, npwx
  USE wavefunctions,  ONLY: evc
  USE nlcc_ph,    ONLY : drc
  USE uspp,       ONLY : nlcc_any
  USE eqv,        ONLY : dvpsi, dmuxc, vlocq
  USE qpoint,     ONLY : xq, eigqts, ikqs, ikks
  USE klist,      ONLY : ngk, igk_k
  USE gc_lr,      ONLY: grho, dvxc_rr,  dvxc_sr,  dvxc_ss, dvxc_s

  USE Coul_cut_2D, ONLY: do_cutoff_2D  
  USE Coul_cut_2D_ph, ONLY : cutoff_localq
  USE qpoint,     ONLY : nksq
  USE becmod,     ONLY : bec_type
  ! 
  IMPLICIT NONE
  !
  !   The dummy variables
  !
  INTEGER, INTENT(in) :: ik
  !! input: the k point
  COMPLEX(DP) :: uact(3*nat)
  !! input: the pattern of displacements
  LOGICAL :: addnlcc
  TYPE(bec_type) :: becp1(nksq), alphap(3,nksq)
  !
  ! ... local variables
  !
  INTEGER ::  na  
  !! counter on atoms
  INTEGER :: mu
  !! counter on modes
  INTEGER :: npw
  !! Number of pw
  INTEGER :: ikk
  !! the point k
  INTEGER :: npwq
  !! Number of q
  INTEGER :: ikq
  !! k-q index
  INTEGER :: iks
  !!
  INTEGER :: ig
  !! counter on G vectors
  INTEGER :: nt
  !! the type of atom
  INTEGER :: ibnd
  !! counter on bands
  INTEGER :: ir 
  !! counter on real mesh
  INTEGER :: is
  !! 
  INTEGER :: ip, nnr, nnp, itmp, itmpp
  !!
  complex(DP) :: gtau, gu, fact, u1, u2, u3, gu0
  complex(DP) , allocatable :: aux (:,:)
  complex(DP) , allocatable :: aux1 (:), aux2 (:)
  complex(DP) , pointer :: auxs (:)
  COMPLEX(DP), ALLOCATABLE :: drhoc(:,:)
  !
#if defined(__CUDA)
  INTEGER, POINTER, DEVICE :: nl_d(:), nlp_d(:)
  !
  nl_d  => dffts%nl_d
  nlp_d  => dfftp%nl_d
#else
  INTEGER, ALLOCATABLE :: nl_d(:)
  INTEGER, ALLOCATABLE :: nlp_d(:)
  !
  ALLOCATE( nl_d(dffts%ngm) )
  ALLOCATE( nlp_d(dfftp%ngm) )
  nl_d  = dffts%nl
  nlp_d  = dfftp%nl
#endif
  ! 
  call start_clock_gpu ('dvqpsi_us')
  allocate (aux1(dffts%nnr))
  allocate (aux2(dffts%nnr))
  !
  !    We start by computing the contribution of the local potential.
  !    The computation of the derivative of the local potential is done in
  !    reciprocal space while the product with the wavefunction is done in
  !    real space
  !
  ikk = ikks(ik)
  ikq = ikqs(ik)
  npw = ngk(ikk)
  npwq= ngk(ikq)
  nnr = dffts%nnr
  ! 
  !$acc data create(aux1(1:nnr),aux2(1:nnr)) copyout(dvpsi) copyin(vlocq,drc,dmuxc) present( igk_k ) deviceptr(nl_d, nlp_d)
  !$acc kernels present(dvpsi,aux1)
  dvpsi(:,:) = (0.d0, 0.d0)
  aux1(:) = (0.d0, 0.d0)
  !$acc end kernels
  do na = 1, nat
     fact = tpiba * (0.d0, -1.d0) * eigqts (na)
     mu = 3 * (na - 1)
     if (abs (uact (mu + 1) ) + abs (uact (mu + 2) ) + abs (uact (mu + &
          3) ) .gt.1.0d-12) then
        nt = ityp (na)
        u1 = uact (mu + 1)
        u2 = uact (mu + 2)
        u3 = uact (mu + 3)
        gu0 = xq (1) * u1 + xq (2) * u2 + xq (3) * u3
        !$acc parallel loop present(eigts1, eigts2, eigts3, mill, g, aux1) 
        do ig = 1, ngms
           gtau = eigts1 (mill(1,ig), na) * eigts2 (mill(2,ig), na) * &
                  eigts3 (mill(3,ig), na)
           gu = gu0 + g (1, ig) * u1 + g (2, ig) * u2 + g (3, ig) * u3
           itmp = nl_d (ig)
           aux1 (itmp ) = aux1 ( itmp ) + vlocq (ig, nt) * gu * &
                fact * gtau
        enddo
        IF (do_cutoff_2D) then  
           !$acc update host(aux1)
           call cutoff_localq( aux1, fact, u1, u2, u3, gu0, nt, na)
           !$acc update device(aux1) 
        ENDIF
        !
     endif
  enddo
  !
  ! add NLCC when present
  !
  if (nlcc_any.and.addnlcc) then
     !CALL errore ('dvqpsi_us', 'openacc fpr ncll_any to be checked', 1)
     allocate (drhoc( dfftp%nnr,nspin))
     allocate (aux( dfftp%nnr,nspin))
     nnp=dfftp%nnr
     !$acc enter data create(drhoc(1:nnp,1:nspin),aux(1:nnp,1:nspin)) 
     !$acc kernels present(drhoc,aux) 
     drhoc(:,:) = (0.d0, 0.d0)
     aux(:,:) = (0.0_dp, 0.0_dp)
     !$acc end kernels 
     do na = 1,nat
        fact = tpiba*(0.d0,-1.d0)*eigqts(na)
        mu = 3*(na-1)
        if (abs(uact(mu+1))+abs(uact(mu+2))  &
                        +abs(uact(mu+3)).gt.1.0d-12) then
           nt=ityp(na)
           u1 = uact(mu+1)
           u2 = uact(mu+2)
           u3 = uact(mu+3)
           gu0 = xq(1)*u1 +xq(2)*u2+xq(3)*u3
           if (upf(nt)%nlcc) then
              !$acc parallel loop present(eigts1, eigts2, eigts3, g, mill,drhoc) 
              do ig = 1,ngm
                 gtau = eigts1(mill(1,ig),na)*   &
                        eigts2(mill(2,ig),na)*   &
                        eigts3(mill(3,ig),na)
                 gu = gu0+g(1,ig)*u1+g(2,ig)*u2+g(3,ig)*u3
                 itmp = nlp_d(ig)
                 drhoc(itmp,1)=drhoc(itmp,1)+drc(ig,nt)*gu*fact*gtau
              enddo
           endif
        endif
     enddo
     !$acc host_data use_device(drhoc)
     CALL invfft ('Rho', drhoc(:,1), dfftp)
     !$acc end host_data
     if (.not.lsda) then
        !$acc parallel loop present(aux,drhoc) 
        do ir=1,nnp
           aux(ir,1) = drhoc(ir,1) * dmuxc(ir,1,1)
        end do
     else
        is=isk(ikk)
        !$acc parallel loop present(drhoc,aux) copyin(is)
        do ir=1,nnp
           drhoc(ir,1) = 0.5d0 * drhoc(ir,1)
           drhoc(ir,2) = drhoc(ir,1)
           aux(ir,1) = drhoc(ir,1) * ( dmuxc(ir,is,1) + &
                                       dmuxc(ir,is,2) )
        enddo
     endif
     rho%of_r(:,1) = rho%of_r(:,1) + rho_core(:)
     !$acc exit data copyout(drhoc)

     IF ( xclib_dft_is('gradient') ) THEN
                    !$acc update host(aux) 
                    CALL dgradcorr (dfftp, rho%of_r, grho, dvxc_rr, &
                    dvxc_sr, dvxc_ss, dvxc_s, xq, drhoc, nspin, nspin_gga, g, aux)    
                    !$acc update device(aux)
     END IF   
     IF (dft_is_nonlocc()) THEN
             !$acc update host(aux)               ! to fix double update
             CALL dnonloccorr(rho%of_r, drhoc, xq, aux)
             !$acc update device(aux)
     END IF
     deallocate (drhoc)

     rho%of_r(:,1) = rho%of_r(:,1) - rho_core(:)

     !$acc host_data use_device(aux)
     CALL fwfft ('Rho', aux(:,1), dfftp)
     !$acc end host_data
! 
!  This is needed also when the smooth and the thick grids coincide to
!  cut the potential at the cut-off
!
     allocate (auxs(dffts%nnr))
     !$acc enter data create(auxs(1:nnr))
     !$acc kernels present(auxs)
     auxs(:) = (0.d0, 0.d0)
     !$acc end kernels
     !$acc parallel loop present(auxs,aux)
     do ig=1,ngms
        itmp = nl_d(ig)
        itmpp = nlp_d(ig) 
        auxs(itmp) = aux(itmpp,1)
     enddo
     !$acc kernels present(aux1,auxs)
     aux1(:) = aux1(:) + auxs(:)
     !$acc end kernels
     !$acc exit data delete(aux, auxs)
     deallocate (aux)
     deallocate (auxs)
  endif
  !
  ! Now we compute dV_loc/dtau in real space
  !
  !$acc update device(evc)
  ! 
  !$acc host_data use_device(aux1)
  CALL invfft ('Rho', aux1, dffts)
  !$acc end host_data
  do ibnd = 1, nbnd
     do ip=1,npol
        !$acc kernels present(aux2)
        aux2(:) = (0.d0, 0.d0)
        !$acc end kernels
        if (ip==1) then
           !$acc parallel loop present(aux2, igk_k) 
           do ig = 1, npw
              itmp = nl_d (igk_k (ig,ikk) )
              aux2 ( itmp ) = evc (ig, ibnd)
           enddo
        else
           !$acc parallel loop present(aux2, igk_k)
           do ig = 1, npw
              itmp = nl_d (igk_k (ig,ikk) )
              aux2 ( itmp ) = evc (ig+npwx, ibnd)
           enddo
        end if
        !
        !  This wavefunction is computed in real space
        !
        !$acc host_data use_device(aux2)
        CALL invfft ('Wave', aux2, dffts)
        !$acc end host_data
        !$acc parallel loop present(aux2, aux1)
        do ir = 1, nnr
           aux2 (ir) = aux2 (ir) * aux1 (ir)
        enddo
        !
        ! and finally dV_loc/dtau * psi is transformed in reciprocal space
        !
        !$acc host_data use_device(aux2)
        CALL fwfft ('Wave', aux2, dffts)
        !$acc end host_data
        if (ip==1) then
           !$acc parallel loop present( aux2, igk_k, dvpsi )
           do ig = 1, npwq
              itmp = nl_d (igk_k (ig,ikq) )
              dvpsi (ig, ibnd) = aux2 ( itmp )
           enddo
        else
           !$acc parallel loop present( aux2, igk_k, dvpsi )
           do ig = 1, npwq
              itmp = nl_d (igk_k (ig,ikq) )
              dvpsi (ig+npwx, ibnd) = aux2 ( itmp )
           enddo
        end if
     enddo
  enddo
  !$acc end data
  !
  deallocate (aux2)
  deallocate (aux1)
  !
  !   We add the contribution of the nonlocal potential in the US form
  !   First a term similar to the KB case.
  !   Then a term due to the change of the D coefficients.
  !
  call dvqpsi_us_only (ik, uact, becp1, alphap)

  call stop_clock_gpu ('dvqpsi_us')
#if !defined(__CUDA)
  DEALLOCATE(nl_d)
  DEALLOCATE(nlp_d)
#endif
  return
end subroutine dvqpsi_us
